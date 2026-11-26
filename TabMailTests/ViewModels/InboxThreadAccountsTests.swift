// InboxThreadAccountsTests.swift
// TabMailTests
//
// A unified-inbox thread can hold emails from more than one account. Its Archive and Delete send
// each email to its own account's folder (pinned with Move and Undo in InboxThreadAcrossAccountsTests);
// here, the mark-as-read setting they use is the one read when the action started.

import Foundation
import GRDB
import Testing
@testable import TabMail

@Suite("Inbox thread actions across accounts", .serialized, .processGlobalState)
@MainActor
struct InboxThreadAccountsTests {

    /// The second account files its Archive and Trash under other names, so a thread action that
    /// sent every email to the first account's folder names would leave its email where it was.
    private static let otherArchivePath = "Other Archive"
    private static let otherTrashPath = "Other Trash"

    private struct Fixture {
        let pool: DatabasePool
        let dir: URL
        let previous: AppDatabase?
        let inbox: Folder
        let otherInbox: Folder
    }

    private func makeFixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        let otherInbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc2")
        try pool.writeWithoutTransaction { db in
            for (id, address) in [("acc1", "one@example.com"), ("acc2", "two@example.com")] {
                var account = Account(emailAddress: address, displayName: "Test", provider: .gmail)
                account.id = id
                try account.insert(db)
            }
            try inbox.insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: "acc1").insert(db)
            try Folder(name: "Trash", path: "Trash", role: .trash, accountId: "acc1").insert(db)
            try otherInbox.insert(db)
            try Folder(name: "Archive", path: Self.otherArchivePath, role: .archive, accountId: "acc2").insert(db)
            try Folder(name: "Trash", path: Self.otherTrashPath, role: .trash, accountId: "acc2").insert(db)
        }
        return Fixture(pool: pool, dir: dir, previous: previous, inbox: inbox, otherInbox: otherInbox)
    }

    private func header(in folder: Folder, messageId: String) -> MessageHeader {
        var header = MessageHeader(
            messageId: messageId, subject: "Subj", from: "Sender", fromAddress: "s@example.com",
            to: "me@example.com", date: Date(), snippet: "snip",
            folderId: folder.id, accountId: folder.accountId, folderPath: folder.path, isInInbox: true)
        header.headerComplete = true
        header.isRead = true
        return header
    }

    private func clearOverlay() {
        AccountManager.shared.removeOverlayEntries(ids: Array(AccountManager.shared.snapshotOverlay().keys))
    }

    @Test("A thread's Archive or Delete uses the mark-as-read setting as it was when the action started, in every account, even if it changes before the queued work runs",
          arguments: [true, false], [true, false])
    func markReadSettingIsTheOneAtTheStart(archive: Bool, onAtStart: Bool) async throws {
        let fixture = try makeFixture()
        let key = AccountManager.markReadOnArchiveDeleteKey
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            InstalledTestDatabaseLifetime.finish(previous: fixture.previous, pool: fixture.pool, directory: fixture.dir)
            clearOverlay()
        }
        clearOverlay()
        UndoService.shared.dismissAll()
        UserDefaults.standard.set(onAtStart, forKey: key)
        // Two accounts, so the action queues one read-then-move per account.
        var own = header(in: fixture.inbox, messageId: "setting-own")
        var other = header(in: fixture.otherInbox, messageId: "setting-other")
        own.isRead = false
        other.isRead = false
        let seeded = [own, other]
        try await fixture.pool.writeWithoutTransaction { db in
            for header in seeded { try header.insert(db) }
        }
        let ids = [own.id, other.id]
        let vm = InboxViewModel(folders: [fixture.inbox, fixture.otherInbox])

        // Hold the write queue so the action's queued work runs only after the setting changes.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        defer { gate.finish() }
        await AccountManager.shared.enqueueWrite {
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let skipped: [String]
        if archive { skipped = vm.archiveThread(ids) } else { skipped = await vm.deleteThread(ids) }
        #expect(skipped.isEmpty)
        #expect(seeded.map { AccountManager.shared.overlayAdjustedSnapshot($0).isRead } == [onAtStart, onAtStart],
                "the rows show the setting as it was at the start")
        UserDefaults.standard.set(!onAtStart, forKey: key)
        gate.finish()
        await AccountManager.shared.awaitWriteQueueDrain()

        let read = try await fixture.pool.read { db in
            try ids.compactMap { try MessageHeader.fetchOne(db, key: $0)?.isRead }
        }
        #expect(read == [onAtStart, onAtStart], "each email's read state follows the setting as it was when the action started")
    }
}
