/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// ADR-IOS-049 — instant in-memory insert of NSE-staged mail into the inbox list,
/// before the merge's durable write.
@Suite("Inbox staged in-memory insert (ADR-IOS-049)")
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
        try pool.writeWithoutTransaction { db in var f = folder; try f.insert(db) }
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
        let (_, folder, dir, previous) = try makeTestDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; try? FileManager.default.removeItem(at: dir) }
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
        let (_, folder, dir, previous) = try makeTestDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; try? FileManager.default.removeItem(at: dir) }
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
        let (_, folder, dir, previous) = try makeTestDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; try? FileManager.default.removeItem(at: dir) }
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
        defer { AppDatabase.shared.withLock { $0 = previous }; try? FileManager.default.removeItem(at: dir) }
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
    @Test("lookupMessage synthesizes from a pending staged row when GRDB has none")
    func lookupSynthesizes() throws {
        let (_, folder, dir, previous) = try makeTestDB()
        defer { AppDatabase.shared.withLock { $0 = previous }; try? FileManager.default.removeItem(at: dir) }
        let vm = InboxViewModel(folders: [folder])
        vm.loadInitialPage()
        vm.insertStagedRows([makeStagedRow(messageId: "m1")])
        let id = MessageIdentity.headerId(accountId: "acc1", folderPath: "INBOX", messageId: "m1")
        let looked = vm.lookupMessage(id)
        #expect(looked != nil)
        #expect(looked?.messageId == "m1")
        // A genuinely-unknown id resolves to nil (no GRDB row, no pending row).
        #expect(vm.lookupMessage("acc1:INBOX:nope") == nil)
    }
}
