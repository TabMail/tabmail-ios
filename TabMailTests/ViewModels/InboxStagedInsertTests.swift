/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// ADR-IOS-049 — instant in-memory insert of NSE-staged mail into the inbox list,
/// before the merge's durable write.
///
/// `.serialized`: `lookupSynthesizes` touches `NSEDataBridge.latestStagedRows` —
/// a process-wide global — mirrors the `.serialized` trait on every other
/// suite that touches it (`InboxListBehaviorPinningTests`,
/// `InboxListReaderIntegrationTests`, `NSEStaleStagedRowInvalidationTests`).
@Suite("Inbox staged in-memory insert (ADR-IOS-049)", .serialized)
struct InboxStagedInsertTests {

    private func makeTestDB() throws -> (pool: DatabasePool, folder: Folder, dir: URL, previous: AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "test@example.com", displayName: "Test", provider: .gmail)
            acc.id = "acc1"
            try acc.insert(db)
        }
        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        try pool.writeWithoutTransaction { db in let f = folder; try f.insert(db) }
        return (pool, folder, dir, previous)
    }

    private func makeStagedRow(
        accountId: String = "acc1",
        folderPath: String = "INBOX",
        messageId: String,
        rfc822: String? = nil,
        isRead: Bool = false
    ) -> StagedInboxRow {
        StagedInboxRow(
            accountId: accountId, folderPath: folderPath, messageId: messageId,
            rfc822MessageId: rfc822, threadId: nil, inReplyTo: nil, references: [],
            subject: "Subj \(messageId)", senderName: "Sender", senderAddress: "s@example.com",
            to: "me@example.com", snippet: "snip", date: Date(),
            isRead: isRead, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil, summaryBlurb: nil
        )
    }

    @Test("toMessageHeader synthesizes a GRDB-shaped, inbox-visible header")
    func synthesis() {
        let h = makeStagedRow(messageId: "m1", rfc822: "<r1@x>", isRead: true).toMessageHeader()
        #expect(h.id == MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m1"))
        #expect(h.folderId == MessageIdentity.folderId(accountId: "acc1", folderPath: "INBOX"))
        #expect(h.messageId == "m1")
        #expect(h.rfc822MessageId == "<r1@x>")
        #expect(h.isInInbox == true)
        #expect(h.headerComplete == true)
        #expect(h.isRead == true)
    }

    @MainActor
    @Test("insertStagedRows adds a staged row to the inbox in-memory")
    func insertsNew() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let vm = InboxViewModel(folders: [folder])
        vm.loadInitialPage()
        #expect(vm.loadedMessages.isEmpty)
        vm.insertStagedRows([makeStagedRow(messageId: "m1")])
        #expect(vm.loadedMessages.count == 1)
        guard vm.loadedMessages.count == 1 else { return }
        #expect(vm.loadedMessages[0].messageId == "m1")
    }

    @MainActor
    @Test("insertStagedRows dedups against already-loaded ids (no double-insert)")
    func dedups() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let vm = InboxViewModel(folders: [folder])
        vm.loadInitialPage()
        let row = makeStagedRow(messageId: "m1")
        vm.insertStagedRows([row])
        vm.insertStagedRows([row])
        #expect(vm.loadedMessages.count == 1)
    }

    @MainActor
    @Test("insertStagedRows skips a row for a non-displayed folder")
    func skipsOtherFolder() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let vm = InboxViewModel(folders: [folder])
        vm.loadInitialPage()
        // folderId = acc1:Archive — not one of the VM's displayed folders.
        vm.insertStagedRows([makeStagedRow(folderPath: "Archive", messageId: "m1")])
        #expect(vm.loadedMessages.isEmpty)
    }

    @MainActor
    @Test("staged reply adopts the on-screen thread's computedThreadId (no singleton flash)")
    func adoptsThreadId() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        // A durable, on-screen message with a real thread id + rfc822 id.
        var parent = MessageHeader(
            messageId: "1000", subject: "Parent", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date().addingTimeInterval(-60), snippet: "p",
            folderId: folder.id, accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        parent.headerComplete = true
        parent.rfc822MessageId = "<parent@x>"
        parent.computedThreadId = "thread-A"
        try pool.writeWithoutTransaction { db in try parent.insert(db) }

        let vm = InboxViewModel(folders: [folder])
        vm.loadInitialPage()
        guard vm.loadedMessages.count == 1 else {
            Issue.record("Expected 1 loaded, got \(vm.loadedMessages.count)"); return
        }

        // Staged reply: In-Reply-To links it to the on-screen parent.
        var reply = makeStagedRow(messageId: "m-reply")
        reply = StagedInboxRow(
            accountId: reply.accountId, folderPath: reply.folderPath, messageId: reply.messageId,
            rfc822MessageId: "<reply@x>", threadId: nil, inReplyTo: "<parent@x>", references: [],
            subject: reply.subject, senderName: reply.senderName, senderAddress: reply.senderAddress,
            to: reply.to, snippet: reply.snippet, date: reply.date,
            isRead: reply.isRead, isFlagged: reply.isFlagged, hasAttachments: reply.hasAttachments,
            isReplied: reply.isReplied, isForwarded: reply.isForwarded,
            actionTag: reply.actionTag, summaryBlurb: reply.summaryBlurb
        )
        vm.insertStagedRows([reply])

        #expect(vm.loadedMessages.count == 2)
        let inserted = vm.loadedMessages.first { $0.messageId == "m-reply" }
        #expect(inserted?.computedThreadId == "thread-A")
        // Grouped immediately: one thread group containing both, not two singletons.
        #expect(vm.displayGroups.count == 1)
    }

    @MainActor
    @Test("identity dedup: staged row with remapped UID but same rfc822MessageId is NOT double-inserted")
    func identityDedupRfc822() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        // Durable, on-screen copy under headerId acc1:INBOX:1000.
        var durable = MessageHeader(
            messageId: "1000", subject: "Dup", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date().addingTimeInterval(-60), snippet: "d",
            folderId: folder.id, accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        durable.headerComplete = true
        durable.rfc822MessageId = "<dup@example.com>"
        try pool.writeWithoutTransaction { db in try durable.insert(db) }
        let vm = InboxViewModel(folders: [folder])
        vm.loadInitialPage()
        guard vm.loadedMessages.count == 1 else {
            Issue.record("Expected 1 loaded, got \(vm.loadedMessages.count)"); return
        }
        // Same message re-staged after an IMAP UID remap: different messageId
        // (→ different headerId, so loadedIds does NOT catch it), same rfc822 id.
        vm.insertStagedRows([makeStagedRow(messageId: "2000", rfc822: "<dup@example.com>")])
        #expect(vm.loadedMessages.count == 1)
    }

    @MainActor
    @Test("identity dedup: staged row with same (accountId, messageId) in a sibling displayed folder is NOT double-inserted")
    func identityDedupMessageId() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let updates = Folder(name: "Updates", path: "Updates", role: .inbox, accountId: "acc1")
        try pool.writeWithoutTransaction { db in let f = updates; try f.insert(db) }
        var durable = MessageHeader(
            messageId: "1000", subject: "Dup", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date().addingTimeInterval(-60), snippet: "d",
            folderId: folder.id, accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        durable.headerComplete = true
        try pool.writeWithoutTransaction { db in try durable.insert(db) }
        let vm = InboxViewModel(folders: [folder, updates])
        vm.loadInitialPage()
        guard vm.loadedMessages.count == 1 else {
            Issue.record("Expected 1 loaded, got \(vm.loadedMessages.count)"); return
        }
        // Same account + messageId, different folderPath → different headerId.
        vm.insertStagedRows([makeStagedRow(folderPath: "Updates", messageId: "1000")])
        #expect(vm.loadedMessages.count == 1)
    }

    @MainActor
    @Test("G3: identity dedup rejects a UID collision with an on-screen row when both sides' rfc822 are known and DISAGREE — both rows render")
    func identityDedupRejectsCrossFolderUidCollisionWithDifferingRfc822() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let updates = Folder(name: "Updates", path: "Updates", role: .inbox, accountId: "acc1")
        try pool.writeWithoutTransaction { db in let f = updates; try f.insert(db) }
        var durable = MessageHeader(
            messageId: "1000", subject: "On screen", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date().addingTimeInterval(-60), snippet: "d",
            folderId: folder.id, accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        durable.headerComplete = true
        durable.rfc822MessageId = "<y@example.com>"
        try pool.writeWithoutTransaction { db in try durable.insert(db) }
        let vm = InboxViewModel(folders: [folder, updates])
        vm.loadInitialPage()
        guard vm.loadedMessages.count == 1 else {
            Issue.record("Expected 1 loaded, got \(vm.loadedMessages.count)"); return
        }
        // Same account + raw UID ("1000") as the on-screen row, different
        // folder → different headerId, and a DIFFERENT rfc822 — provably a
        // different message (IMAP UIDs are per-folder, ADR-IOS-042). Pre-G3
        // fix, the bare (accountId, messageId) comparator wrongly treated
        // this as a duplicate of the on-screen row and dropped it.
        vm.insertStagedRows([makeStagedRow(folderPath: "Updates", messageId: "1000", rfc822: "<z@example.com>")])
        #expect(vm.loadedMessages.count == 2, "the genuinely different message must NOT be suppressed by the UID collision")
    }

    @MainActor
    @Test("identity dedup: collision with rfc822 known on only ONE side still dedups (conservative default, unchanged by G3)")
    func identityDedupStillMatchesWhenOnlyOneSideHasRfc822() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        let updates = Folder(name: "Updates", path: "Updates", role: .inbox, accountId: "acc1")
        try pool.writeWithoutTransaction { db in let f = updates; try f.insert(db) }
        var durable = MessageHeader(
            messageId: "1000", subject: "Dup", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date().addingTimeInterval(-60), snippet: "d",
            folderId: folder.id, accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        durable.headerComplete = true
        durable.rfc822MessageId = "<known@example.com>"
        try pool.writeWithoutTransaction { db in try durable.insert(db) }
        let vm = InboxViewModel(folders: [folder, updates])
        vm.loadInitialPage()
        guard vm.loadedMessages.count == 1 else {
            Issue.record("Expected 1 loaded, got \(vm.loadedMessages.count)"); return
        }
        // Same account + raw UID, different folder → different headerId. The
        // staged row's rfc822 is unknown (nil) — can't PROVE a difference, so
        // the conservative messageId match still applies (G3 only rejects
        // when BOTH sides are known and disagree).
        vm.insertStagedRows([makeStagedRow(folderPath: "Updates", messageId: "1000", rfc822: nil)])
        #expect(vm.loadedMessages.count == 1, "nil rfc822 on one side must fall back to conservative messageId dedup")
    }

    @MainActor
    @Test("identity dedup is account-scoped: same messageId on ANOTHER account still inserts")
    func identityDedupAccountScoped() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; TestDatabaseTeardown.retire(pool: pool, directory: dir) }
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "two@example.com", displayName: "Two", provider: .gmail)
            acc.id = "acc2"
            try acc.insert(db)
        }
        let inbox2 = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        try pool.writeWithoutTransaction { db in let f = inbox2; try f.insert(db) }
        var durable = MessageHeader(
            messageId: "1000", subject: "A1", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date().addingTimeInterval(-60), snippet: "d",
            folderId: folder.id, accountId: "acc1", folderPath: "INBOX", isInInbox: true
        )
        durable.headerComplete = true
        try pool.writeWithoutTransaction { db in try durable.insert(db) }
        let vm = InboxViewModel(folders: [folder, inbox2])
        vm.loadInitialPage()
        guard vm.loadedMessages.count == 1 else {
            Issue.record("Expected 1 loaded, got \(vm.loadedMessages.count)"); return
        }
        vm.insertStagedRows([makeStagedRow(accountId: "acc2", messageId: "1000")])
        #expect(vm.loadedMessages.count == 2)
    }

    @MainActor
    @Test("lookupMessage synthesizes from NSEDataBridge.latestStagedRows when GRDB has none")
    func lookupSynthesizes() throws {
        let (pool, folder, dir, previous) = try makeTestDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
            NSEDataBridge.latestStagedRows.withLock { $0 = [] }
        }
        let vm = InboxViewModel(folders: [folder])
        vm.loadInitialPage()
        let row = makeStagedRow(messageId: "m1")
        // PLAN_INBOX_UNIFIED_READ.md §3: `lookupMessage`'s synthesis fallback
        // now reads `NSEDataBridge.latestStagedRows` directly (the deleted
        // `pendingStagedRows` used to synthesize from whatever
        // `insertStagedRows` had been handed) — seed the global to mirror the
        // merge's publish-before-post order.
        NSEDataBridge.latestStagedRows.withLock { $0 = [row] }
        vm.insertStagedRows([row])
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m1")
        let looked = vm.lookupMessage(id)
        #expect(looked != nil)
        #expect(looked?.messageId == "m1")
        // A genuinely-unknown id resolves to nil (no GRDB row, no staged row).
        #expect(vm.lookupMessage("acc1:INBOX:nope") == nil)
    }
}
