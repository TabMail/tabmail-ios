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
/// already published. Every writer of the opened email reaches it: pull-to-refresh, the
/// open's own resolve, and the body poll's header recovery after the open lost the header.
///
/// And when one opened email is replaced by another, the thread is reloaded, so the email
/// opened before comes back to the chat's rows while the thread still holds it, also when the
/// replacement lands under a preview freeze; and the earlier/later split follows the new one.
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

        /// The opened id at each publication of `message` (nil while none is opened), so a case
        /// can show which transitions its writers made.
        private(set) var openedAtPublication: [String?] = []

        private func check(_ vm: MessageDetailViewModel, after field: MessageDetailViewModel.DisplayField) {
            checks += 1
            if field == .message { openedAtPublication.append(vm.message?.id) }
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
            for id in kept where id != openedId && rows.filter({ $0 == id }).count != 1 {
                found.append("after \(field): the row \(id) is not in the chat's rows exactly once: \(rows)")
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


    /// A wait that ran out: the test fails here instead of asserting on a state it never reached.
    struct TimedOut: Error, CustomStringConvertible {
        let what: String
        var description: String { "timed out waiting for \(what)" }
    }

    @MainActor
    private func waitUntil(_ what: String, seconds: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw TimedOut(what: what) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The server fetch every case uses unless it names its own: stores a body for the email.
    private static func storeBody(_ msg: MessageHeader, in pool: DatabasePool) async throws {
        let key = ContentKey(rawValue: msg.id)
        try await pool.write { db in
            try MessageBody(contentKey: key, htmlContent: "<p>refetched</p>").insert(db, onConflict: .replace)
        }
    }

    /// In order: each publication of the opened email, each thread scan asked for (with the
    /// opened email it starts from), and each display read point a reader reached.
    @MainActor
    final class Timeline {
        enum Event: Equatable {
            case opened(String?)
            case scanAsked(String)
            case read(MessageDetailViewModel.DisplayReadPoint)
        }

        /// One change of the opened id, and whether a thread scan from the new one was asked
        /// for at that very change, before anything else happened.
        struct Change {
            let from: String?
            let to: String?
            let index: Int
            let scanAskedAtOnce: Bool
        }

        private(set) var events: [Event] = []
        private let openedAtStart: String?

        init(_ vm: MessageDetailViewModel) {
            openedAtStart = vm.message?.id
            let previousPublication = vm._publicationHook
            vm._publicationHook = { [weak self, weak vm] field in
                previousPublication?(field)
                guard let self, let vm, field == .message else { return }
                self.events.append(.opened(vm.message?.id))
            }
            let previousRequest = vm._threadScanRequestHook
            vm._threadScanRequestHook = { [weak self] anchor in
                previousRequest?(anchor)
                self?.events.append(.scanAsked(anchor))
            }
            let previousRead = vm._displayReadHook
            vm._displayReadHook = { [weak self] point in
                await previousRead?(point)
                self?.events.append(.read(point))
            }
        }

        var changes: [Change] {
            var result: [Change] = []
            var current = openedAtStart
            for (i, event) in events.enumerated() {
                guard case .opened(let id) = event, id != current else { continue }
                let askedAtOnce = id.map { i > 0 && events[i - 1] == .scanAsked($0) } ?? false
                result.append(Change(from: current, to: id, index: i, scanAskedAtOnce: askedAtOnce))
                current = id
            }
            return result
        }

        /// Changes from one opened email to another.
        var replacements: [Change] { changes.filter { $0.from != nil && $0.to != nil } }
        /// Changes from no opened email to one.
        var firstOpens: [Change] { changes.filter { $0.from == nil && $0.to != nil } }

        /// Thread scans that read the store after the event at `index`.
        func scansRead(after index: Int) -> Int {
            events.suffix(from: min(index + 1, events.count)).filter { $0 == .read(.threadScan) }.count
        }

        func reached(_ point: MessageDetailViewModel.DisplayReadPoint) -> Bool { events.contains(.read(point)) }
        func scansAsked(after index: Int) -> Int {
            events.suffix(from: min(index + 1, events.count)).filter { if case .scanAsked = $0 { return true } else { return false } }.count
        }
    }

    /// Holds a server fetch until `open()`.
    @MainActor
    final class FetchGate {
        private(set) var reached = false
        private var isOpen = false
        private var waiter: CheckedContinuation<Void, Never>?

        func hold() async {
            reached = true
            if !isOpen { await withCheckedContinuation { waiter = $0 } }
        }

        func open() {
            isOpen = true
            waiter?.resume()
            waiter = nil
        }
    }

    /// Awaits every thread scan asked for since the timeline was installed (each has read and
    /// published, or was skipped for a newer one), then checks no display reader runs or waits.
    @MainActor
    private func settle(_ vm: MessageDetailViewModel) async {
        await vm.settleThreadScansForTesting()
        #expect(vm.displayTurnIsIdleForTesting, "control: every display reader has finished")
    }

    /// Every one of `ids` still stored is the opened email or exactly one row, so a whole-chat
    /// action takes it once.
    @MainActor
    private func expectEveryStoredCopyListedOnce(
        _ vm: MessageDetailViewModel, among ids: [String], pool: DatabasePool
    ) async throws {
        let stored = try await pool.read { db in try MessageHeader.filter(keys: ids).fetchAll(db).map(\.id) }
        #expect(!stored.isEmpty, "control: the fixture's emails are stored")
        let rows = vm.chatRows.map(\.id)
        for id in stored {
            #expect(rows.filter { $0 == id }.count == 1, "the stored email \(id) is the opened email or exactly one row: \(rows)")
        }
    }

    /// A replacement of one opened email by another asked for a thread scan at once, and a scan
    /// read the store after it.
    @MainActor
    private func expectReloadAfterEveryReplacement(_ timeline: Timeline) {
        let replacements = timeline.replacements
        #expect(!replacements.isEmpty, "control: one opened email replaced another")
        for change in replacements {
            #expect(change.scanAskedAtOnce, "replacing \(change.from ?? "nil") with \(change.to ?? "nil") reloads the thread")
            #expect(timeline.scansRead(after: change.index) >= 1, "a thread scan read the store after the replacement")
        }
    }

    /// One Gmail email under two labels (the opened Inbox copy and its All Mail copy) and a
    /// reply to it, stored.
    private func insertCopyThread(into pool: DatabasePool) throws -> (inboxCopy: MessageHeader, allMailCopy: MessageHeader, reply: MessageHeader) {
        let gmailId = "opened-\(UUID().uuidString)"
        let rfc = "<\(gmailId)@example.com>"
        let inboxCopy = header(gmailId, folder: "INBOX", rfc: rfc, minutesAgo: 30)
        let allMailCopy = header(gmailId, folder: "Archive", rfc: rfc, minutesAgo: 30)
        let reply = header("reply-\(UUID().uuidString)", folder: "INBOX", rfc: "<reply-\(gmailId)@example.com>",
                           inReplyTo: rfc, minutesAgo: 10)
        try insert([inboxCopy, allMailCopy, reply], into: pool)
        return (inboxCopy, allMailCopy, reply)
    }

    /// Opens `opened` with the thread loaded, as the screen shows it.
    @MainActor
    private func openWithThread(
        _ opened: MessageHeader, pool: DatabasePool,
        fetchBody: ((MessageHeader) async throws -> Void)? = nil
    ) async throws -> MessageDetailViewModel {
        let vm = MessageDetailViewModel(
            messageId: opened.id, dbPool: pool,
            fetchBodyOverride: fetchBody ?? { msg in try await Self.storeBody(msg, in: pool) },
            observeNotifications: true)
        vm._testSeedMessage(opened)
        NotificationCenter.default.post(name: .nseMergeDidCommit, object: Self.testPostSentinel)
        try await waitUntil("the thread to load") { vm.hasLoadedThread && vm.displayTurnIsIdleForTesting }
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
        let timeline = Timeline(vm)
        try await removeInboxCopy(inboxCopy, from: pool)
        await vm.refetchBody()
        await settle(vm)

        #expect(vm.message?.id == allMailCopy.id, "precondition: the open re-resolved onto the All Mail copy")
        expectReloadAfterEveryReplacement(timeline)
        #expect(violations.checks > 0, "control: the publications were checked")
        #expect(violations.found.isEmpty, "\(violations.found)")
        #expect(vm.chatRows.map(\.id).sorted() == [allMailCopy.id, reply.id, replyAllMailCopy.id].sorted(),
                "a whole-chat action takes the opened email and both copies of the reply, each once")
        try await expectEveryStoredCopyListedOnce(
            vm, among: [inboxCopy.id, allMailCopy.id, reply.id, replyAllMailCopy.id], pool: pool)
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

        let violations = Violations(vm, keeping: [later.id])
        let timeline = Timeline(vm)
        try await removeInboxCopy(inboxCopy, from: pool)
        await vm.refetchBody()
        await settle(vm)

        #expect(vm.message?.id == allMailCopy.id, "precondition: the open re-resolved onto the All Mail copy")
        expectReloadAfterEveryReplacement(timeline)
        #expect(violations.checks > 0, "control: the publications were checked")
        #expect(violations.found.isEmpty, "\(violations.found)")
        #expect(vm.threadMessages.map(\.id) == [later.id])
        #expect((vm.earlierMessages + vm.laterMessages).map(\.id) == [later.id],
                "the screen shows the later email once and the opened email only as the opened one")
        try await expectEveryStoredCopyListedOnce(vm, among: [inboxCopy.id, allMailCopy.id, later.id], pool: pool)
    }

    @MainActor
    @Test("the chat never lists the opened email twice when the open's own resolve replaces the opened email with one of its copies")
    func openResolveOntoACopyListsItOnce() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let (inboxCopy, allMailCopy, reply) = try insertCopyThread(into: pool)

        let vm = try await openWithThread(inboxCopy, pool: pool)
        defer { vm.cancelBodyPollForTesting() }
        #expect(vm.threadMessages.map(\.id) == [reply.id], "precondition: the chat shows the reply")
        #expect(vm.threadCopies.map(\.id) == [allMailCopy.id], "precondition: the All Mail copy is a hidden copy")

        let violations = Violations(vm, keeping: [reply.id])
        let timeline = Timeline(vm)
        // The Inbox label goes before the open reads: its resolve finds the All Mail copy.
        try await removeInboxCopy(inboxCopy, from: pool)
        await vm.loadBody()
        await settle(vm)

        #expect(timeline.reached(.openResolve), "control: the open's resolve ran")
        #expect(timeline.changes.first.map { $0.from == inboxCopy.id && $0.to == allMailCopy.id } == true,
                "control: the open's resolve replaced the opened Inbox copy with the All Mail copy")
        #expect(vm.message?.id == allMailCopy.id)
        expectReloadAfterEveryReplacement(timeline)
        #expect(violations.checks > 0, "control: the publications were checked")
        #expect(violations.found.isEmpty, "\(violations.found)")
        #expect(vm.chatRows.map(\.id).sorted() == [allMailCopy.id, reply.id].sorted(),
                "a whole-chat action takes the opened email and the reply, each once")
        try await expectEveryStoredCopyListedOnce(vm, among: [inboxCopy.id, allMailCopy.id, reply.id], pool: pool)
    }

    @MainActor
    @Test("the chat never lists the opened email twice when a copy becomes the opened one after the opened email was lost, and that asks for no extra scan")
    func copyRecoveredAfterTheOpenedOneWasLostIsListedOnce() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let (inboxCopy, allMailCopy, reply) = try insertCopyThread(into: pool)
        let inboxCopyId = inboxCopy.id

        // The Inbox label goes while the open fetches the Inbox copy's body: the open reads the
        // header back, finds nothing and publishes no opened email. The body poll recovers the
        // header onto the All Mail copy, then fetches that copy's body.
        let vm = try await openWithThread(inboxCopy, pool: pool, fetchBody: { msg in
            if msg.id == inboxCopyId {
                try await pool.write { db in
                    try db.execute(sql: "DELETE FROM messageHeader WHERE id = ?", arguments: [inboxCopyId])
                }
            } else {
                try await Self.storeBody(msg, in: pool)
            }
        })
        defer { vm.cancelBodyPollForTesting() }
        #expect(vm.threadMessages.map(\.id) == [reply.id], "precondition: the chat shows the reply")
        #expect(vm.threadCopies.map(\.id) == [allMailCopy.id], "precondition: the All Mail copy is a hidden copy")

        let violations = Violations(vm, keeping: [reply.id])
        let timeline = Timeline(vm)
        await vm.loadBody()
        // The poll's first server fetch comes after its 2s tick; it publishes the body and the
        // header and asks for its scan in one display turn.
        try await waitUntil("the poll to recover the All Mail copy and its body", seconds: 8) {
            vm.message?.id == allMailCopy.id && vm.messageBody != nil
        }
        await settle(vm)

        #expect(timeline.reached(.openReread), "control: the open read the header back after its fetch")
        #expect(timeline.changes.map(\.to) == [nil, allMailCopy.id],
                "control: the open published no opened email, then the poll recovered the All Mail copy")
        #expect(timeline.replacements.isEmpty, "control: no opened email replaced another")
        let firstOpens = timeline.firstOpens
        #expect(firstOpens.count == 1, "control: the recovery opened the All Mail copy where none was opened")
        for change in firstOpens {
            #expect(!change.scanAskedAtOnce, "opening an email where none was opened asks for no extra scan")
        }
        #expect(vm.messageBody != nil, "control: the poll fetched the body")
        #expect(violations.checks > 0, "control: the publications were checked")
        #expect(violations.found.isEmpty, "\(violations.found)")
        #expect(vm.chatRows.map(\.id).sorted() == [allMailCopy.id, reply.id].sorted(),
                "a whole-chat action takes the opened email and the reply, each once")
        try await expectEveryStoredCopyListedOnce(vm, among: [inboxCopy.id, allMailCopy.id, reply.id], pool: pool)
    }

    /// The Inbox copy is on screen from the notification's snapshot but not stored yet; the All
    /// Mail copy and a reply are stored. The open's resolve misses the Inbox copy and finds the
    /// All Mail copy; the Inbox copy is stored right after that read, so both copies are live
    /// when the open publishes. The open's server fetch is held, so its own scan cannot run.
    @MainActor
    private func openOntoAnotherCopyWhileTheFirstIsStored(
        pool: DatabasePool, gate: FetchGate
    ) async throws -> (vm: MessageDetailViewModel, inboxCopy: MessageHeader, allMailCopy: MessageHeader, reply: MessageHeader) {
        let gmailId = "opened-\(UUID().uuidString)"
        let rfc = "<\(gmailId)@example.com>"
        let inboxCopy = header(gmailId, folder: "INBOX", rfc: rfc, minutesAgo: 30)
        let allMailCopy = header(gmailId, folder: "Archive", rfc: rfc, minutesAgo: 30)
        let reply = header("reply-\(UUID().uuidString)", folder: "INBOX", rfc: "<reply-\(gmailId)@example.com>",
                           inReplyTo: rfc, minutesAgo: 10)
        try insert([allMailCopy, reply], into: pool)

        let vm = try await openWithThread(inboxCopy, pool: pool, fetchBody: { msg in
            await gate.hold()
            try await Self.storeBody(msg, in: pool)
        })
        #expect(vm.threadMessages.map(\.id) == [reply.id], "precondition: the chat shows the reply")
        #expect(vm.threadCopies.map(\.id) == [allMailCopy.id], "precondition: the All Mail copy is a hidden copy")

        let storedInboxCopy = inboxCopy
        vm._displayReadHook = { point in
            guard point == .openResolve else { return }
            do {
                try await pool.write { db in try storedInboxCopy.insert(db, onConflict: .ignore) }
            } catch {
                Issue.record("storing the Inbox copy failed: \(error)")
            }
        }
        return (vm, inboxCopy, allMailCopy, reply)
    }

    @MainActor
    @Test("when another copy replaces the opened email, the copy opened before comes back to the chat's rows while it is still stored")
    func previousCopyComesBackAfterTheOpenedOneIsReplaced() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let gate = FetchGate()
        let (vm, inboxCopy, allMailCopy, reply) = try await openOntoAnotherCopyWhileTheFirstIsStored(pool: pool, gate: gate)
        defer { vm.cancelBodyPollForTesting() }
        let ids = [inboxCopy.id, allMailCopy.id, reply.id]

        let violations = Violations(vm, keeping: [reply.id])
        let timeline = Timeline(vm)
        let load = Task { await vm.loadBody() }
        // The held fetch is released and the open joined on every way out, so no task outlives
        // the fixture.
        do {
            try await waitUntil("the open to reach its server fetch") { gate.reached }
            // Only the reload can scan while the open's fetch is held.
            await settle(vm)
            #expect(vm.message?.id == allMailCopy.id, "control: the open replaced the Inbox copy with the All Mail copy")
            expectReloadAfterEveryReplacement(timeline)
            #expect(violations.found.isEmpty, "\(violations.found)")
            let rows = vm.chatRows.map(\.id)
            #expect(rows.sorted() == ids.sorted(),
                    "a whole-chat action takes every stored copy, the Inbox copy included: \(rows)")
            try await expectEveryStoredCopyListedOnce(vm, among: ids, pool: pool)
        } catch {
            gate.open()
            await load.value
            throw error
        }
        gate.open()
        await load.value
        await settle(vm)
        #expect(violations.found.isEmpty, "\(violations.found)")
        let finalRows = vm.chatRows.map(\.id)
        #expect(finalRows.sorted() == ids.sorted(), "the open's own scan keeps every stored copy: \(finalRows)")
        try await expectEveryStoredCopyListedOnce(vm, among: ids, pool: pool)
    }

    @MainActor
    @Test("when another copy replaces the opened email during a preview, the copy opened before comes back to the chat's rows when the preview ends")
    func previousCopyComesBackAfterAReplacementDuringAPreview() async throws {
        let (pool, dir, previous) = try makePool()
        defer {
            PreviewFreezeGate.shared.end()
            cleanUp(pool, dir, previous)
        }
        let gate = FetchGate()
        let (vm, inboxCopy, allMailCopy, reply) = try await openOntoAnotherCopyWhileTheFirstIsStored(pool: pool, gate: gate)
        defer { vm.cancelBodyPollForTesting() }
        let ids = [inboxCopy.id, allMailCopy.id, reply.id]

        let violations = Violations(vm, keeping: [reply.id])
        let timeline = Timeline(vm)
        PreviewFreezeGate.shared.begin()
        let load = Task { await vm.loadBody() }
        do {
            try await waitUntil("the open to reach its server fetch") { gate.reached }
            await settle(vm)
            #expect(vm.message?.id == allMailCopy.id, "control: the open replaced the Inbox copy during the preview")
            let replacement = timeline.replacements.first
            #expect(replacement != nil, "control: one opened email replaced another")
            #expect(replacement.map { timeline.scansRead(after: $0.index) } == 0,
                    "control: nothing reloads the thread while the preview is shown")
            #expect(!vm.chatRows.contains(where: { $0.id == inboxCopy.id }),
                    "control: the copy opened before is not back yet")

            PreviewFreezeGate.shared.end()
            // The release replays the reload the replacement asked for.
            try await waitUntil("the preview's end to reload the thread") {
                replacement.map { timeline.scansAsked(after: $0.index) } ?? 0 >= 1
            }
            await settle(vm)
            #expect(replacement.map { timeline.scansRead(after: $0.index) } ?? 0 >= 1,
                    "a thread scan read the store after the preview ended")
            #expect(violations.found.isEmpty, "\(violations.found)")
            let rows = vm.chatRows.map(\.id)
            #expect(rows.sorted() == ids.sorted(),
                    "a whole-chat action takes every stored copy, the Inbox copy included: \(rows)")
            try await expectEveryStoredCopyListedOnce(vm, among: ids, pool: pool)
        } catch {
            PreviewFreezeGate.shared.end()
            gate.open()
            await load.value
            throw error
        }
        gate.open()
        await load.value
        await settle(vm)
        #expect(violations.found.isEmpty, "\(violations.found)")
        try await expectEveryStoredCopyListedOnce(vm, among: ids, pool: pool)
    }

    @MainActor
    @Test("when a hidden copy becomes the opened email, a thread email on the same second moves to its side of the new opened one")
    func splitFollowsTheNewOpenedEmail() async throws {
        let (pool, dir, previous) = try makePool()
        defer { cleanUp(pool, dir, previous) }
        let gmailId = "opened-\(UUID().uuidString)"
        let rfc = "<\(gmailId)@example.com>"
        // Three emails on the same second, so only the id orders them. The ids are
        // `<account>:<folder>:<provider id>`: the All Mail copy ("Archive:opened-…") sorts before
        // the reply ("INBOX:a-…"), which sorts before the Inbox copy ("INBOX:opened-…").
        let inboxCopy = header(gmailId, folder: "INBOX", rfc: rfc, minutesAgo: 30)
        var allMailCopy = header(gmailId, folder: "Archive", rfc: rfc, minutesAgo: 30)
        var sameSecond = header("a-\(UUID().uuidString)", folder: "INBOX", rfc: "<reply-\(gmailId)@example.com>",
                                inReplyTo: rfc, minutesAgo: 30)
        allMailCopy.date = inboxCopy.date
        sameSecond.date = inboxCopy.date
        #expect(allMailCopy.id < sameSecond.id && sameSecond.id < inboxCopy.id, "precondition: the ids order the three")
        try insert([inboxCopy, allMailCopy, sameSecond], into: pool)

        let vm = try await openWithThread(inboxCopy, pool: pool)
        defer { vm.cancelBodyPollForTesting() }
        #expect(vm.threadCopies.map(\.id) == [allMailCopy.id], "precondition: the All Mail copy is a hidden copy")
        #expect(vm.earlierMessages.map(\.id) == [sameSecond.id] && vm.laterMessages.isEmpty,
                "precondition: the same-second email shows before the Inbox copy")

        let violations = Violations(vm, keeping: [sameSecond.id])
        let timeline = Timeline(vm)
        try await removeInboxCopy(inboxCopy, from: pool)
        await vm.refetchBody()
        await settle(vm)

        #expect(vm.message?.id == allMailCopy.id, "precondition: the open re-resolved onto the All Mail copy")
        expectReloadAfterEveryReplacement(timeline)
        #expect(violations.found.isEmpty, "\(violations.found)")
        #expect(vm.threadMessages.map(\.id) == [sameSecond.id], "control: the thread rows did not change")
        #expect(vm.earlierMessages.isEmpty, "the same-second email no longer shows before the opened email")
        #expect(vm.laterMessages.map(\.id) == [sameSecond.id], "the same-second email shows after the All Mail copy")
    }
}
