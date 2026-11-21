/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// ADR-IOS-114: a bubble's card opens today's detail of that email.
///
/// THE SYSTEM PROPERTY pinned here: the card marks read only the email the bubble showed. On IMAP
/// a UIDVALIDITY reset can put a different email at the same address before the detail resolves
/// it; the card passes the bubble's Message-ID with the address, so the detail marks nothing read
/// then. The unchanged email is still marked read (the control). The same holds for a chat opened
/// from search on an email with no Message-ID: it carries the address epoch search found.
///
/// The account is Gmail: the witness check is the same for every provider, and a Gmail read's queued
/// operation fails at once here, where an IMAP one would try to connect and hold the shared write
/// queue into the next suite.
///
/// `.serialized, .processGlobalState`: the harness swaps `AppDatabase.shared` and reads
/// `AccountManager.shared`'s write queue and intent-cycle register.
@Suite("Chat card opens the email the bubble showed", .serialized, .processGlobalState)
@MainActor
struct ChatCardIdentityTests {
    private static let account = "acc-chat-card"

    private func makeDB() throws -> (DatabasePool, Folder, URL, AppDatabase?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path, configuration: config)
        let appDb = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let prev = current; current = appDb; return prev
        }
        var inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: Self.account)
        inbox.lastKnownUidValidity = 11
        try pool.writeWithoutTransaction { db in
            var acc = Account(emailAddress: "user@example.com", displayName: "User", provider: .gmail)
            acc.id = Self.account
            try acc.insert(db)
            let folder = inbox
            try folder.insert(db)
        }
        return (pool, inbox, dir, previous)
    }

    private func header(rfc: String, inbox: Folder) -> MessageHeader {
        var h = MessageHeader(
            messageId: "4242", subject: "Plans", from: "Sender", fromAddress: "sender@example.com",
            to: "user@example.com", date: Date(), snippet: "", folderId: inbox.id,
            accountId: inbox.accountId, folderPath: inbox.path, isInInbox: true)
        h.rfc822MessageId = rfc
        h.headerComplete = true
        h.observedUidValidity = 11
        return h
    }

    private func intentCycles() -> [String] {
        AccountManager.shared.pendingIntentCyclesForTesting().keys.filter { $0.hasPrefix("\(Self.account):") }
    }

    private func clearShared() {
        AccountManager.shared.removeOverlayEntries(ids: Array(AccountManager.shared.snapshotOverlay().keys))
        NSEDataBridge.latestStagedRows.withLock { $0 = [] }
    }

    /// Every write admitted so far has run, the ones a gesture's registration enqueues on an
    /// unstructured hop included (a raw FIFO barrier can overtake that hop).
    private func drainWriteQueue() async {
        await AccountManager.shared.awaitWriteQueueDrain()
    }

    /// The card's open, as `ChatThreadView`'s card sheet makes it: the bubble's address and its
    /// Message-ID.
    private func openCard(for bubble: MessageHeader, pool: DatabasePool) async {
        let vm = MessageDetailViewModel(
            messageId: bubble.id, dbPool: pool, fetchBodyOverride: { _ in },
            expectedRfc822MessageId: bubble.rfc822MessageId)
        await vm.markReadOnOpenIfNeeded()
    }

    @Test("A card whose address now holds a different email marks nothing read; an unchanged one is marked read",
          arguments: [false, true])
    func cardMarksOnlyTheBubblesEmail(reseated: Bool) async throws {
        let (pool, inbox, dir, previous) = try makeDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir); clearShared() }
        clearShared()
        let bubble = header(rfc: "<shown@example.com>", inbox: inbox)
        try await pool.write { db in try bubble.insert(db) }
        let seated = reseated ? header(rfc: "<replacement@example.com>", inbox: inbox) : bubble
        if reseated {
            #expect(seated.id == bubble.id, "the replacement sits at the same address")
            try await pool.write { db in
                try bubble.delete(db)
                try seated.insert(db)
            }
        }
        // Hold the write queue so a registered read is still observable below.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }
        await openCard(for: bubble, pool: pool)
        #expect(intentCycles() == (reseated ? [] : [bubble.id]), "a read is registered only for the email the bubble showed")
        gate.finish()
        await drainWriteQueue()
        let after = try await pool.read { db in try MessageHeader.fetchOne(db, key: seated.id) }
        #expect(after?.rfc822MessageId == seated.rfc822MessageId)
        #expect(after?.isRead == !reseated)
    }

    // MARK: - A chat opened from search on a row with no Message-ID

    /// The same property for the chat itself, opened from search as `MessageOpenView` opens it for
    /// a row with no Message-ID: the address and the epoch search found it under. The chat's own
    /// view model is the one its init builds (read before the view is installed, so the State's
    /// initial value), and its open marks read through `markReadOnOpenIfNeeded`, as `noteMembers`
    /// does for the opened email.
    @Test("A chat opened from search on an address re-seated under a new epoch marks nothing read; an unchanged one is marked read",
          arguments: [false, true])
    func searchChatMarksOnlyTheEmailSearchFound(reseated: Bool) async throws {
        let (pool, inbox, dir, previous) = try makeDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir); clearShared() }
        clearShared()
        var found = header(rfc: "<unused@example.com>", inbox: inbox)
        found.rfc822MessageId = nil
        let searchedEpoch = try #require(found.observedUidValidity)
        let shown = found
        try await pool.write { db in try shown.insert(db) }
        var seated = shown
        if reseated {
            // A UIDVALIDITY reset puts another email without a Message-ID at the same address.
            seated.subject = "Another email"
            seated.observedUidValidity = searchedEpoch + 1
        }
        let atAddress = seated
        if reseated {
            #expect(atAddress.id == shown.id, "the replacement sits at the same address")
            try await pool.write { db in
                try shown.delete(db)
                try atAddress.insert(db)
            }
        }
        // Hold the write queue so a registered read is still observable below.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }
        let chat = ChatThreadView(messageId: shown.id, expectedObservedUidValidity: searchedEpoch)
        await chat.viewModel.markReadOnOpenIfNeeded()
        let registered = intentCycles()
        let expected: [String] = reseated ? [] : [shown.id]
        #expect(registered == expected, "a read is registered only for the email search found")
        gate.finish()
        await drainWriteQueue()
        let after = try await pool.read { db in try MessageHeader.fetchOne(db, key: atAddress.id) }
        let afterSubject = after?.subject
        let afterRead = after?.isRead
        #expect(afterSubject == atAddress.subject, "control: the row at the address is the one the test put there")
        #expect(afterRead == !reseated)
    }

    /// The handoff itself, from search's destination on: `SearchView.destination` builds the open a
    /// result's tap navigates to, and the open (`MessageOpenView`) builds the chat or today's detail
    /// from it, whichever the Chat View setting routes to. The view model each builds gets the epoch
    /// search found: on an address re-seated under a new epoch its open marks nothing read; on the
    /// unchanged address (the same-epoch control) the email is marked read.
    @Test("Search's open carries the epoch it found to the chat's and to the detail's view model",
          arguments: [true, false], [false, true])
    func searchOpenCarriesTheEpoch(opensInChat: Bool, reseated: Bool) async throws {
        let (pool, inbox, dir, previous) = try makeDB()
        defer { InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir); clearShared() }
        clearShared()
        var found = header(rfc: "<unused@example.com>", inbox: inbox)
        found.rfc822MessageId = nil
        let searchedEpoch = try #require(found.observedUidValidity)
        let shown = found
        try await pool.write { db in try shown.insert(db) }
        var seated = shown
        if reseated {
            // A UIDVALIDITY reset puts another email without a Message-ID at the same address.
            seated.subject = "Another email"
            seated.observedUidValidity = searchedEpoch + 1
        }
        let atAddress = seated
        if reseated {
            #expect(atAddress.id == shown.id, "the replacement sits at the same address")
            try await pool.write { db in
                try shown.delete(db)
                try atAddress.insert(db)
            }
        }
        let target = SearchView.OpenTarget(
            headerId: shown.id, provenRfc822MessageId: nil, provenObservedUidValidity: searchedEpoch)
        let open = SearchView.destination(for: target)
        let route = MessageOpenView.route(
            messageId: open.messageId, expectedRfc822MessageId: open.expectedRfc822MessageId,
            expectedObservedUidValidity: open.expectedObservedUidValidity,
            opensInChat: opensInChat, pool: PrioritizedDatabase(pool: pool))
        let expectedRoute: MessageOpenView.Route = opensInChat ? .chat : .detail
        #expect(route == expectedRoute, "control: the open goes to the \(opensInChat ? "chat" : "detail")")
        // Hold the write queue so a registered read is still observable below.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }
        // The view model the routed view builds (its State's initial value, read before the view
        // is installed).
        let viewModel = opensInChat ? open.chat.viewModel : open.detail.viewModel
        await viewModel.markReadOnOpenIfNeeded()
        let registered = intentCycles()
        let expected: [String] = reseated ? [] : [shown.id]
        #expect(registered == expected, "a read is registered only for the email search found")
        gate.finish()
        await drainWriteQueue()
        let after = try await pool.read { db in try MessageHeader.fetchOne(db, key: atAddress.id) }
        let afterSubject = after?.subject
        let afterRead = after?.isRead
        #expect(afterSubject == atAddress.subject, "control: the row at the address is the one the test put there")
        #expect(afterRead == !reseated)
    }

    @Test("The chat's card passes the bubble's Message-ID with its address")
    func cardWiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("TabMail/Views/Chat/ChatThreadView.swift"), encoding: .utf8)
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flat.components(separatedBy: "MessageDetailView(messageId: msg.id, expectedRfc822MessageId: msg.rfc822MessageId)").count == 2)
        #expect(!flat.contains("MessageDetailView(messageId: msg.id)"))
    }
}
