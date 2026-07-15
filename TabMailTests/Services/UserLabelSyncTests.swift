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
                try UserLabel(id: labelId, accountId: "acc1", name: labelId, isSystem: false)
                    .insert(db, onConflict: .ignore)
                try MessageUserLabel(messageId: header.id, accountId: "acc1", userLabelId: labelId)
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
            try UserLabel(id: "L1", accountId: "acc1", name: "Work", isSystem: false)
                .insert(db, onConflict: .ignore)
            try MessageUserLabel(messageId: header.id, accountId: "acc1", userLabelId: "L1")
                .insert(db, onConflict: .ignore)
        }
        try db.write { db in
            try UserLabel(id: "L1", accountId: "acc1", name: "Work", isSystem: false)
                .insert(db, onConflict: .ignore)
            try MessageUserLabel(messageId: header.id, accountId: "acc1", userLabelId: "L1")
                .insert(db, onConflict: .ignore)
        }

        let count = try db.read { try MessageUserLabel.fetchCount($0) }
        #expect(count == 1)
    }

    // MARK: - MessageSnapshot with Labels

    @Test("MessageSnapshot carries userLabels from loadLabels")
    func snapshotWithLabels() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        let header = try TestDatabase.insertMessageHeader(db)

        try db.write { db in
            try UserLabel(id: "L1", accountId: "acc1", name: "Work", isSystem: false).insert(db)
            try UserLabel(id: "L2", accountId: "acc1", name: "Play", isSystem: false).insert(db)
            try MessageUserLabel(messageId: header.id, accountId: "acc1", userLabelId: "L1").insert(db)
            try MessageUserLabel(messageId: header.id, accountId: "acc1", userLabelId: "L2").insert(db)
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
            try UserLabel(id: "L1", accountId: "acc1", name: "Work", isSystem: false).insert(db)
            try UserLabel(id: "L2", accountId: "acc1", name: "Personal", isSystem: false).insert(db)
            try MessageUserLabel(messageId: msg1.id, accountId: "acc1", userLabelId: "L1").insert(db)
            try MessageUserLabel(messageId: msg2.id, accountId: "acc1", userLabelId: "L2").insert(db)
        }

        // Load labels for both messages (simulating thread union)
        let allIds = [msg1.id, msg2.id]
        let labelsByMsg = try db.read { db in
            try UserLabelStore.loadLabels(for: allIds, in: db)
        }

        // Union: collect all labels, deduplicate by account + provider ID.
        var seenLabels: Set<UserLabelIdentity> = []
        var unionLabels: [UserLabel] = []
        for id in allIds {
            for label in labelsByMsg[id] ?? [] {
                if seenLabels.insert(label.scopedIdentity).inserted {
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
            try UserLabel(id: "L1", accountId: "acc1", name: "Work", isSystem: false).insert(db)
            // Both messages have the same label
            try MessageUserLabel(messageId: msg1.id, accountId: "acc1", userLabelId: "L1").insert(db)
            try MessageUserLabel(messageId: msg2.id, accountId: "acc1", userLabelId: "L1").insert(db)
        }

        let allIds = [msg1.id, msg2.id]
        let labelsByMsg = try db.read { db in
            try UserLabelStore.loadLabels(for: allIds, in: db)
        }

        var seenLabels: Set<UserLabelIdentity> = []
        var unionLabels: [UserLabel] = []
        for id in allIds {
            for label in labelsByMsg[id] ?? [] {
                if seenLabels.insert(label.scopedIdentity).inserted {
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
        let label = UserLabel(id: "Label_1", accountId: "acc1", name: "Work/Projects/Alpha", isSystem: false)
        let segments = UserLabelDisplaySegment.expand([label])
        let names = segments.map(\.displayName)
        #expect(names == ["Alpha", "Projects", "Work"]) // Alphabetical
        // All segments point to the same parent label
        #expect(segments.allSatisfy { $0.parentLabel.id == "Label_1" })
    }

    @Test("UserLabelDisplaySegment deduplicates shared segments across labels")
    func expandDeduplicates() {
        let label1 = UserLabel(id: "L1", accountId: "acc1", name: "Work/Alpha", isSystem: false)
        let label2 = UserLabel(id: "L2", accountId: "acc1", name: "Work/Beta", isSystem: false)
        let segments = UserLabelDisplaySegment.expand([label1, label2])
        let names = segments.map(\.displayName)
        #expect(names == ["Alpha", "Beta", "Work"]) // "Work" appears once, not twice
    }

    @Test("UserLabelDisplaySegment handles non-nested labels")
    func expandNonNested() {
        let label = UserLabel(id: "L1", accountId: "acc1", name: "Simple", isSystem: false)
        let segments = UserLabelDisplaySegment.expand([label])
        #expect(segments.count == 1)
        #expect(segments[0].displayName == "Simple")
    }
}

@Suite("UserLabel menu durable admission", .serialized, .processGlobalState)
@MainActor
struct UserLabelMenuAdmissionTests {
    private func makeTestDB(provider: AccountProvider = .gmail) throws -> (
        pool: DatabasePool,
        header: MessageHeader,
        label: UserLabel,
        dir: URL,
        previous: AppDatabase?
    ) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: dir.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prior = current
            current = appDatabase
            return prior
        }

        var account = Account(
            emailAddress: "user-label@example.com",
            displayName: "Test",
            provider: provider
        )
        account.id = "user-label-admission-account"
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: account.id)
        var header = MessageHeader(
            messageId: "provider-message-id",
            subject: "Label admission",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date(),
            snippet: "Body",
            folderId: inbox.id,
            accountId: account.id,
            folderPath: inbox.path,
            isInInbox: true
        )
        header.headerComplete = true
        header.rfc822MessageId = "  <label-action@example.com>  "
        let label = UserLabel(
            id: "Label_Test",
            accountId: account.id,
            name: "Test Label",
            isSystem: false
        )
        let storedHeader = header
        try pool.writeWithoutTransaction { db in
            try account.insert(db)
            try inbox.insert(db)
            try storedHeader.insert(db)
            try label.insert(db)
        }
        return (pool, storedHeader, label, dir, previous)
    }

    private func restoreTestDB(previous: AppDatabase?, dir: URL) {
        AppDatabase.shared.withLock { $0 = previous }
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("real menu apply/remove transactions preserve local final state behind RFC admission")
    func applyAndRemoveUseProductionTransaction() async throws {
        let (pool, header, label, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        let menu = UserLabelMenuView(messageSnapshot: MessageSnapshot(from: header))
        let appliedResult = await menu.applyLabel(label)
        #expect(appliedResult)
        let applied = try await pool.read { db in
            try MessageUserLabel
                .filter(Column("messageId") == header.id && Column("userLabelId") == label.id)
                .fetchCount(db)
        }
        #expect(applied == 1)
        let applyOperations = try await pool.read { db in
            try PendingOperation.fetchAll(db)
        }
        #expect(applyOperations.count == 1)
        guard applyOperations.count == 1 else { return }
        #expect(applyOperations[0].type == .addUserLabel)
        #expect(applyOperations[0].messageIds == ["label-action@example.com"])
        #expect(applyOperations[0].accountId == header.accountId)
        #expect(applyOperations[0].folderPath == header.folderPath)
        #expect(applyOperations[0].userLabelId == label.id)

        let removedResult = await menu.removeLabel(label)
        #expect(removedResult)
        let remaining = try await pool.read { db in
            try MessageUserLabel
                .filter(Column("messageId") == header.id && Column("userLabelId") == label.id)
                .fetchCount(db)
        }
        #expect(remaining == 0)
        let allOperations = try await pool.read { db in
            try PendingOperation.order(Column("createdAt")).fetchAll(db)
        }
        #expect(allOperations.count == 2)
        guard allOperations.count == 2 else { return }
        #expect(allOperations.map(\.type) == [.addUserLabel, .removeUserLabel])
        #expect(allOperations.allSatisfy { $0.messageIds == ["label-action@example.com"] })
    }

    @Test("real menu transaction rechecks fresh header identity before local or durable mutation")
    func freshInvalidHeaderRefusesApply() async throws {
        let (pool, header, label, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        let menu = UserLabelMenuView(messageSnapshot: MessageSnapshot(from: header))
        try await pool.writeWithoutTransaction { db in
            try db.execute(
                sql: "UPDATE messageHeader SET rfc822MessageId = NULL WHERE id = ?",
                arguments: [header.id]
            )
        }

        let appliedResult = await menu.applyLabel(label)
        #expect(!appliedResult)
        let result = try await pool.read { db in
            (
                try MessageUserLabel.fetchCount(db),
                try PendingOperation.fetchCount(db)
            )
        }
        #expect(result.0 == 0)
        #expect(result.1 == 0)
    }

    @Test("real menu transaction refuses a label owned by another account")
    func mismatchedLabelAccountRefusesMutation() async throws {
        let (pool, header, label, dir, previous) = try makeTestDB()
        defer { restoreTestDB(previous: previous, dir: dir) }

        let foreignLabel = UserLabel(
            id: label.id,
            accountId: "different-account",
            name: "Different Account Label",
            isSystem: false
        )
        let menu = UserLabelMenuView(messageSnapshot: MessageSnapshot(from: header))

        #expect(!(await menu.applyLabel(foreignLabel)))
        #expect(!(await menu.removeLabel(foreignLabel)))
        let result = try await pool.read { db in
            (
                try MessageUserLabel.fetchCount(db),
                try PendingOperation.fetchCount(db)
            )
        }
        #expect(result.0 == 0)
        #expect(result.1 == 0)
    }

    @Test(
        "unsupported providers refuse menu label admission without changing final local or durable state",
        arguments: [AccountProvider.outlook, .caldav]
    )
    func unsupportedProviderRefusesMutation(provider: AccountProvider) async throws {
        let (pool, header, label, dir, previous) = try makeTestDB(provider: provider)
        defer { restoreTestDB(previous: previous, dir: dir) }

        let menu = UserLabelMenuView(messageSnapshot: MessageSnapshot(from: header))
        #expect(!(await menu.applyLabel(label)))

        try await pool.writeWithoutTransaction { db in
            try MessageUserLabel(
                messageId: header.id,
                accountId: header.accountId,
                userLabelId: label.id
            ).insert(db, onConflict: .ignore)
        }
        #expect(!(await menu.removeLabel(label)))

        let final = try await pool.read { db in
            (
                try MessageUserLabel
                    .filter(Column("messageId") == header.id && Column("userLabelId") == label.id)
                    .fetchCount(db),
                try PendingOperation.fetchCount(db)
            )
        }
        #expect(final.0 == 1)
        #expect(final.1 == 0)
    }
}
