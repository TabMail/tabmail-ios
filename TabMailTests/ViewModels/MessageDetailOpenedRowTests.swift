/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// The opened email is never also one of the thread's rows (tabmail-ios #1000, #1001).
///
/// THE SYSTEM PROPERTY pinned here, checked at EVERY publication of the screen's
/// fields (`_publicationHook`), so a duplicate that a later thread load repairs is
/// still caught at the publication that made it:
///  - the email screen never lists the opened email among the thread's messages
///    (`threadMessages`, and its earlier/later split), so it never shows it twice;
///  - the chat's rows (`chatRows`, what a whole-chat Archive, Trash or Move acts on)
///    hold each row once.
///
/// The way in is an email that becomes the opened one while it is already a row: the
/// opened Inbox copy of a Gmail email loses its Inbox label, and pull-to-refresh
/// re-resolves the open onto the email's All Mail copy, which the thread load had
/// already published.
///
/// `.serialized`, `.processGlobalState`: the view model observes process-wide
/// notifications and the test installs the shared `AppDatabase`.
@Suite("The opened email is never also a thread row", .serialized, .processGlobalState)
struct MessageDetailOpenedRowTests {

    /// Sentinel `object` for test posts of `.nseMergeDidCommit`, so count contracts in
    /// other suites can exclude them (production posts `nil`).
    static let testPostSentinel = "MessageDetailOpenedRowTests"

    private static let accountId = "acc-opened-row"

    /// Every publication that broke the property, described.
    @MainActor
    final class Violations {
        private(set) var found: [String] = []
        private(set) var checks = 0
        /// Rows that are not the opened email and must stay in the chat's rows, once each,
        /// wherever the opened email is published: leaving the rows is for the opened email only.
        private let kept: [String]

        /// Checks the property at every publication of `vm`'s screen fields from now on.
        init(_ vm: MessageDetailViewModel, keeping kept: [String] = []) {
            self.kept = kept
            let previous = vm._publicationHook
            vm._publicationHook = { [weak self, weak vm] field in
                previous?(field)
                guard let self, let vm else { return }
                self.check(vm, after: field)
            }
        }

        private func check(_ vm: MessageDetailViewModel, after field: MessageDetailViewModel.DisplayField) {
            checks += 1
            let rows = vm.chatRows.map(\.id)
            if Set(rows).count != rows.count {
                found.append("after \(field): a chat row is listed twice: \(rows)")
            }
            guard let openedId = vm.message?.id else { return }
            if vm.threadMessages.contains(where: { $0.id == openedId }) {
                found.append("after \(field): the opened email \(openedId) is also a thread message")
            }
            // The earlier/later split is recomputed after `threadMessages` is assigned, so it
            // is checked where the opened email is published.
            if field == .message,
               (vm.earlierMessages + vm.laterMessages).contains(where: { $0.id == openedId }) {
                found.append("after \(field): the email screen lists the opened email \(openedId) in its thread")
            }
            if field == .message {
                for id in kept where id != openedId && rows.filter({ $0 == id }).count != 1 {
                    found.append("after \(field): the row \(id) is not in the chat's rows exactly once: \(rows)")
                }
            }
        }
    }

    private func makePool() throws -> (pool: DatabasePool, dir: URL, previous: AppDatabase?) {
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
            acc.id = Self.accountId
            try acc.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.accountId).insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: Self.accountId).insert(db)
        }
        return (pool, dir, previous)
    }

    private func cleanUp(_ pool: DatabasePool, _ dir: URL, _ previous: AppDatabase?) {
        InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
    }

    /// One Gmail row. `providerId` is the Gmail id, shared by every label's copy.
    private func header(
        _ providerId: String, folder: String, rfc: String?, inReplyTo: String? = nil,
        threadId: String? = nil, minutesAgo: Double
    ) -> MessageHeader {
        var h = MessageHeader(
            messageId: providerId, subject: "Launch plan", from: "Sam", fromAddress: "sam@example.com",
            to: "me@example.com", date: Date().addingTimeInterval(-minutesAgo * 60), snippet: "Note",
            folderId: MessageIdentity.folderId(accountId: Self.accountId, folderPath: folder),
            accountId: Self.accountId, folderPath: folder, isInInbox: folder == "INBOX")
        h.rfc822MessageId = rfc
        h.inReplyTo = inReplyTo
        h.threadId = threadId
        h.headerComplete = true
        h.bodyComplete = true
        return h
    }

    private func insert(_ headers: [MessageHeader], into pool: DatabasePool) throws {
        try pool.writeWithoutTransaction { db in
            for h in headers { try h.insert(db) }
        }
    }

    /// The Inbox label is removed: the Inbox copy leaves the device.
    private func removeInboxCopy(_ header: MessageHeader, from pool: DatabasePool) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [header.id])
        }
    }

    @MainActor
    private func waitUntil(seconds: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Opens `opened` with the thread loaded, as the screen shows it.
    @MainActor
    private func openWithThread(_ opened: MessageHeader, pool: DatabasePool) async throws -> MessageDetailViewModel {
        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool,
            fetchBodyOverride: { msg in
                let key = ContentKey(rawValue: msg.id)
                try await pool.write { db in
                    try MessageBody(contentKey: key, htmlContent: "<p>refetched</p>").insert(db, onConflict: .replace)
                }
            },
            observeNotifications: true)
        vm._testSeedMessage(opened)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil { vm.hasLoadedThread && vm.displayTurnIsIdleForTesting }
        return vm
    }

    @MainActor
    @Test("the chat never lists the opened email twice when it becomes the opened one as one of its copies, and keeps every other row")
    func copyThatBecomesTheOpenedOneIsListedOnce() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let gmailId = "opened-\(UUID().uuidString)"
        let rfc = "<\(gmailId)@example.com>"
        // One Gmail email under two labels, and a reply to it, also under two labels. The reply's
        // All Mail copy is a few seconds older only so that the chat shows its Inbox copy and
        // hides this one.
        let inboxCopy = header(gmailId, folder: "INBOX", rfc: rfc, minutesAgo: 30)
        let allMailCopy = header(gmailId, folder: "Archive", rfc: rfc, minutesAgo: 30)
        let replyId = "reply-\(UUID().uuidString)"
        let replyRfc = "<reply-\(gmailId)@example.com>"
        let reply = header(replyId, folder: "INBOX", rfc: replyRfc, inReplyTo: rfc, minutesAgo: 10)
        let replyAllMailCopy = header(replyId, folder: "Archive", rfc: replyRfc, inReplyTo: rfc, minutesAgo: 10.1)
        try insert([inboxCopy, allMailCopy, reply, replyAllMailCopy], into: pool)

        let vm = try await openWithThread(inboxCopy, pool: pool)
        defer { vm.cancelBodyPollForTesting() }
        #expect(vm.threadMessages.map(\.id) == [reply.id], "precondition: the chat shows the reply")
        #expect(Set(vm.threadCopies.map(\.id)) == [allMailCopy.id, replyAllMailCopy.id],
                "precondition: both All Mail copies are hidden copies")

        // The reply and its other copy are not the opened email: they stay in the rows.
        let violations = Violations(vm, keeping: [reply.id, replyAllMailCopy.id])
        try await removeInboxCopy(inboxCopy, from: pool)
        await vm.refetchBody()
        try await waitUntil { vm.displayTurnIsIdleForTesting }

        #expect(vm.message?.id == allMailCopy.id, "precondition: the open re-resolved onto the All Mail copy")
        #expect(violations.checks > 0, "control: the publications were checked")
        #expect(violations.found.isEmpty, "\(violations.found)")
        #expect(vm.chatRows.map(\.id).sorted() == [allMailCopy.id, reply.id, replyAllMailCopy.id].sorted(),
                "a whole-chat action takes the opened email and both copies of the reply, each once")
    }

    @MainActor
    @Test("the email screen never shows the opened email twice when it becomes the opened one as a thread message")
    func threadMessageThatBecomesTheOpenedOneIsShownOnce() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let gmailId = "opened-\(UUID().uuidString)"
        let threadId = "thread-\(UUID().uuidString)"
        // An email with no Message-ID under two labels, so the thread shows the other label's
        // copy as a message of its own (nothing tells the two apart), and a later email of the
        // same Gmail thread.
        let inboxCopy = header(gmailId, folder: "INBOX", rfc: nil, threadId: threadId, minutesAgo: 30)
        let allMailCopy = header(gmailId, folder: "Archive", rfc: nil, threadId: threadId, minutesAgo: 30)
        let later = header("later-\(UUID().uuidString)", folder: "INBOX", rfc: "<later-\(gmailId)@example.com>",
                           threadId: threadId, minutesAgo: 10)
        try insert([inboxCopy, allMailCopy, later], into: pool)

        let vm = try await openWithThread(inboxCopy, pool: pool)
        defer { vm.cancelBodyPollForTesting() }
        #expect(Set(vm.threadMessages.map(\.id)) == [allMailCopy.id, later.id],
                "precondition: the screen shows the All Mail copy as a thread message")

        let violations = Violations(vm)
        try await removeInboxCopy(inboxCopy, from: pool)
        await vm.refetchBody()
        try await waitUntil { vm.displayTurnIsIdleForTesting }

        #expect(vm.message?.id == allMailCopy.id, "precondition: the open re-resolved onto the All Mail copy")
        #expect(violations.checks > 0, "control: the publications were checked")
        #expect(violations.found.isEmpty, "\(violations.found)")
        #expect(vm.threadMessages.map(\.id) == [later.id])
        #expect((vm.earlierMessages + vm.laterMessages).map(\.id) == [later.id],
                "the screen shows the later email once and the opened email only as the opened one")
    }
}
