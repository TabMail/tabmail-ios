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
/// from search on an email with no Message-ID: it carries the address epoch search found. A search
/// open never shows the draft editor for a draft that is not the one search found, whether its
/// Message-ID or, for a draft with none, its address epoch tells them apart.
///
/// The account is Gmail: the witness check is the same for every provider, and a Gmail read's queued
/// operation fails at once here, where an IMAP one would try to connect and hold the shared write
/// queue into the next suite.
///
/// `.serialized, .processGlobalState`: the harness swaps `AppDatabase.shared` and reads
/// `AccountManager.shared`'s write queue and intent-cycle register; the search opens set the Chat
/// View and AI settings (and put them back).
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
    /// result's tap navigates to, the open routes as its body does (`route(pool:)`, with the Chat
    /// View setting it took when it was made), and it builds the chat or today's detail it shows.
    /// The view model each builds gets the epoch search found: on an address re-seated under a new
    /// epoch its open marks nothing read; on the unchanged address (the same-epoch control) the
    /// email is marked read. The chat glows the email search found.
    @Test("Search's open carries the epoch it found to the chat's and to the detail's view model",
          arguments: [true, false], [false, true])
    func searchOpenCarriesTheEpoch(opensInChat: Bool, reseated: Bool) async throws {
        let (pool, inbox, dir, previous) = try makeDB()
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        defer {
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
            clearShared()
        }
        clearShared()
        saved.setChatView(on: opensInChat)
        let live = ChatViewConfig.opensInChat
        #expect(live == opensInChat, "control: the Chat View setting routes opens to the \(opensInChat ? "chat" : "detail")")
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
        let route = open.route(pool: PrioritizedDatabase(pool: pool))
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
        let viewModel: MessageDetailViewModel
        if opensInChat {
            let chat = open.chat
            let highlights = chat.highlightsOpenedMessage
            #expect(highlights, "the chat search opens glows the email search found")
            viewModel = chat.viewModel
        } else {
            viewModel = open.detail.viewModel
        }
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

    /// Search found a draft with no Message-ID under one epoch; a UIDVALIDITY reset then put another
    /// draft at the same address under a new epoch. The open search's destination builds routes as
    /// its body does: the replacement never opens in the draft editor, and the chat or the detail
    /// shown instead marks nothing read. Without a witness the same address opens in the draft
    /// editor (the control that the row there is a draft).
    @Test("Search's open of a draft re-seated under a new epoch shows no draft editor and marks nothing read",
          arguments: [true, false])
    func searchOpenOfAReplacedDraft(opensInChat: Bool) async throws {
        let (pool, _, dir, previous) = try makeDB()
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        defer {
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
            clearShared()
        }
        clearShared()
        saved.setChatView(on: opensInChat)
        let searchedEpoch = 11
        var drafts = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: Self.account)
        drafts.lastKnownUidValidity = searchedEpoch + 1
        let draftsFolder = drafts
        var found = MessageHeader(
            messageId: "4343", subject: "Draft search found", from: "User", fromAddress: "user@example.com",
            to: "sender@example.com", date: Date(), snippet: "", folderId: draftsFolder.id,
            accountId: Self.account, folderPath: draftsFolder.path, isInInbox: false)
        found.headerComplete = true
        found.observedUidValidity = searchedEpoch
        let shown = found
        // A UIDVALIDITY reset puts another draft without a Message-ID at the same address.
        var replacement = found
        replacement.subject = "Another draft"
        replacement.observedUidValidity = searchedEpoch + 1
        let seated = replacement
        #expect(seated.id == shown.id, "the replacement sits at the same address")
        try await pool.write { db in
            try draftsFolder.insert(db)
            try shown.insert(db)
        }
        try await pool.write { db in
            try shown.delete(db)
            try seated.insert(db)
        }
        let database = PrioritizedDatabase(pool: pool)
        let fetched = try await pool.read { db in try MessageHeader.fetchOne(db, key: seated.id) }
        let stored = try #require(fetched)
        let unwitnessed = MessageOpenView(messageId: shown.id).route(pool: database)
        #expect(unwitnessed == .draftEditor(stored), "control: without a witness the address opens in the draft editor")

        let target = SearchView.OpenTarget(
            headerId: shown.id, provenRfc822MessageId: nil, provenObservedUidValidity: searchedEpoch)
        let open = SearchView.destination(for: target)
        let route = open.route(pool: database)
        let expectedRoute: MessageOpenView.Route = opensInChat ? .chat : .detail
        #expect(route == expectedRoute,
                "the replacement never opens in the draft editor; the \(opensInChat ? "chat" : "detail") refuses it instead")
        // Hold the write queue so a registered read is still observable below.
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        await AccountManager.shared.enqueueWrite {
            var it = gateStream.makeAsyncIterator()
            _ = await it.next()
        }
        let viewModel = opensInChat ? open.chat.viewModel : open.detail.viewModel
        await viewModel.markReadOnOpenIfNeeded()
        let registered = intentCycles()
        #expect(registered.isEmpty, "no read is registered for the replacement")
        gate.finish()
        await drainWriteQueue()
        let after = try await pool.read { db in try MessageHeader.fetchOne(db, key: seated.id) }
        let afterSubject = after?.subject
        let afterRead = after?.isRead
        #expect(afterSubject == seated.subject, "control: the row at the address is the replacement")
        #expect(afterRead == false, "the replacement stays unread")
    }

    /// Search found a draft by its Message-ID; the draft now at that address has another
    /// Message-ID, under the same address epoch. A usable Message-ID is the witness, ahead of the
    /// epoch: the open search's destination builds, routed as its body routes it, never opens the
    /// other draft in the draft editor. The control: an open carrying the Message-ID of the draft
    /// there opens it in the draft editor.
    @Test("Search's open of a draft whose Message-ID is not the one search found shows no draft editor; a matching one does",
          arguments: [true, false])
    func searchOpenOfADraftWithAnotherMessageID(opensInChat: Bool) async throws {
        let (pool, _, dir, previous) = try makeDB()
        let saved = ChatSummaryQueueTests.SavedChatViewState()
        defer {
            saved.restore()
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: dir)
            clearShared()
        }
        clearShared()
        saved.setChatView(on: opensInChat)
        let epoch = 11
        var drafts = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: Self.account)
        drafts.lastKnownUidValidity = epoch
        let draftsFolder = drafts
        var draft = MessageHeader(
            messageId: "4444", subject: "Another draft", from: "User", fromAddress: "user@example.com",
            to: "sender@example.com", date: Date(), snippet: "", folderId: draftsFolder.id,
            accountId: Self.account, folderPath: draftsFolder.path, isInInbox: false)
        draft.rfc822MessageId = "<other@example.com>"
        draft.headerComplete = true
        draft.observedUidValidity = epoch
        let atAddress = draft
        try await pool.write { db in
            try draftsFolder.insert(db)
            try atAddress.insert(db)
        }
        let database = PrioritizedDatabase(pool: pool)
        let fetched = try await pool.read { db in try MessageHeader.fetchOne(db, key: atAddress.id) }
        let stored = try #require(fetched)

        let mismatched = SearchView.destination(for: SearchView.OpenTarget(
            headerId: atAddress.id, provenRfc822MessageId: "<found@example.com>", provenObservedUidValidity: epoch))
        let route = mismatched.route(pool: database)
        let expectedRoute: MessageOpenView.Route = opensInChat ? .chat : .detail
        #expect(route == expectedRoute,
                "another Message-ID at the address never opens in the draft editor; the \(opensInChat ? "chat" : "detail") refuses it instead")

        let matching = SearchView.destination(for: SearchView.OpenTarget(
            headerId: atAddress.id, provenRfc822MessageId: "<other@example.com>", provenObservedUidValidity: epoch))
        let matchingRoute = matching.route(pool: database)
        #expect(matchingRoute == .draftEditor(stored), "control: the draft's own Message-ID opens it in the draft editor")
    }

    /// The two lines no unit test can reach, pinned by source. Search's destination is registered
    /// inside SearchView's own NavigationStack, whose path only a tap on a live search result
    /// fills, so it is read here: it shows exactly the open `SearchView.destination` builds (the
    /// tests above drive that open). `MessageOpenView`'s body shows the route `route(pool:)`
    /// computes, the one the tests above take, and is the only caller of the static route.
    @Test("Search registers one destination, built by SearchView.destination; the open's body shows route(pool:)")
    func searchOpenWiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func flat(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let search = try flat("TabMail/Views/Inbox/SearchView.swift")
        #expect(search.components(separatedBy: ".navigationDestination(").count == 2, "search registers one destination")
        #expect(search.components(separatedBy: ".navigationDestination(for: OpenTarget.self) { target in Self.destination(for: target) }").count == 2,
                "a result's tap shows the open SearchView.destination builds")
        let open = try flat("TabMail/Views/Chat/MessageOpenView.swift")
        #expect(open.components(separatedBy: "var body: some View { switch route(pool: AppDatabase.dbPool) {").count == 2,
                "the body shows the route route(pool:) computes")
        #expect(open.components(separatedBy: "Self.route(").count == 2, "the static route has one caller, route(pool:)")
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
