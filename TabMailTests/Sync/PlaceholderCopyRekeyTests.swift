/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// A sent email shows in Sent at once, and a saved draft in Drafts, under a
/// placeholder id (`sent-…`, `draft-…`) that no server holds. When a sync stores
/// the server's copy, it deletes the placeholder in the same write. A view that
/// still holds the placeholder (an open reply, a detail view, a thread bubble)
/// must then name the copy: a reply, a move or a thread read after it names the
/// row that exists, with no reopen.
///
/// The property: every sync path that replaces a placeholder by the server's
/// copy posts that move (`MailPointerMove`) once its write has committed, and
/// an open detail view follows it. A row with a real provider id is never
/// re-pointed this way. Each test asserts what is posted or what the open view
/// names.
///
/// `.serialized, .processGlobalState`: these tests replace `AppDatabase.shared`,
/// observe a process-wide notification and toggle `PreviewFreezeGate.shared`.
@Suite("Placeholder replaced by the server's copy", .serialized, .processGlobalState)
struct PlaceholderCopyRekeyTests {

    // MARK: - Fixture

    /// One account with one folder, in an installed app database.
    struct Fixture {
        let pool: DatabasePool
        let dir: URL
        let previous: AppDatabase?
        let folder: Folder

        var accountId: String { folder.accountId }

        static func make(provider: AccountProvider, role: FolderRole, path: String) throws -> Fixture {
            let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
            let accountId = "pcr-\(UUID().uuidString.prefix(8).lowercased())"
            var account = Account(emailAddress: "\(accountId)@example.com", displayName: "T", provider: provider)
            account.id = accountId
            let folder = Folder(name: path, path: path, role: role, accountId: accountId)
            let toInsert = account
            try pool.write { db in
                try toInsert.insert(db)
                try folder.insert(db)
            }
            return Fixture(pool: pool, dir: dir, previous: previous, folder: folder)
        }

        func tearDown() {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        /// A stored row as an optimistic send or draft save, or an earlier sync,
        /// leaves it.
        @discardableResult
        func insertRow(_ messageId: String, rfc822: String, date: Date = Date()) throws -> MessageHeader {
            var header = MessageHeader(
                messageId: messageId, subject: "Stored \(messageId)", from: "Fixture",
                fromAddress: "sender@example.com", to: "recipient@example.com", date: date,
                snippet: "stored", folderId: folder.id, accountId: accountId, folderPath: folder.path,
                isInInbox: false, providerDate: date)
            header.rfc822MessageId = rfc822
            header.headerComplete = true
            let toInsert = header
            try pool.write { db in try toInsert.insert(db) }
            return header
        }

        func headerId(_ messageId: String) -> String {
            MessageIdentity.headerId(accountId: accountId, folderPath: folder.path, messageId: messageId)
        }

        func storedIds() throws -> Set<String> {
            try pool.read { db in
                Set(try MessageHeader.filter(Column("folderId") == folder.id).fetchAll(db).map(\.id))
            }
        }
    }

    /// The server's copy as a listing returns it.
    static func listed(_ messageId: String, rfc822: String, date: Date = Date()) -> MessageHeaderInfo {
        MessageHeaderInfo(
            messageId: messageId, rfc822MessageId: rfc822, inReplyTo: nil, references: [],
            threadId: nil, subject: "Stored copy", from: "Fixture", fromAddress: "sender@example.com",
            to: "recipient@example.com", cc: "", bcc: "", replyTo: nil, date: date, snippet: "copy",
            isRead: true, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil)
    }

    /// The record a placeholder replaced by the copy posts: not provider
    /// authority, no epoch, and the email's stable id before and after.
    static func replacement(
        of oldHeaderId: String, by newHeaderId: String, providerId: String, stableIds: StableIds? = nil
    ) -> HeaderRekeyRecord {
        HeaderRekeyRecord(
            oldHeaderId: oldHeaderId, newHeaderId: newHeaderId,
            newProviderMessageId: providerId, carriesProviderAuthority: false,
            stableIds: stableIds)
    }

    /// The row moves posted for one account while `body` runs (other suites
    /// may post their own at the same time).
    final class PostedRekeys: Sendable {
        private let records = Mutex<[HeaderRekeyRecord]>([])
        private let accountPrefix: String

        init(accountId: String) { accountPrefix = "\(accountId):" }

        var all: [HeaderRekeyRecord] { records.withLock { $0 } }

        func observing(_ body: () async throws -> Void) async throws {
            let token = start()
            defer { NotificationCenter.default.removeObserver(token) }
            try await body()
        }

        /// Starts collecting until the returned observer is removed, for a
        /// main-actor test that cannot hand `observing` its body.
        func start() -> any NSObjectProtocol {
            NotificationCenter.default.addObserver(
                forName: .mailPointersMoved, object: nil, queue: nil
            ) { [self] notification in
                guard let posted = MailPointerMoves.posted(in: notification) else { return }
                let mine = posted.moves.compactMap { move -> HeaderRekeyRecord? in
                    guard case .row(let record) = move,
                          record.oldHeaderId.hasPrefix(accountPrefix) else { return nil }
                    return record
                }
                records.withLock { $0 += mine }
            }
        }
    }

    /// Polls every 20 ms until `condition` holds or `seconds` pass.
    @MainActor
    private func waitUntil(seconds: Double = 3, _ condition: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 50) where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Which rows are followed

    @Test("Only a placeholder's replacement is followed; a real provider id is not")
    func onlyAPlaceholderIsFollowed() {
        func row(_ messageId: String) -> MessageHeader {
            MessageHeader(
                messageId: messageId, subject: "s", from: "f", fromAddress: "f@example.com",
                to: "t@example.com", date: Date(), snippet: "", folderId: "a:Sent", accountId: "a",
                folderPath: "Sent", isInInbox: false)
        }
        let copy = row("500")
        let sent = SyncEngine.placeholderReplacement(of: row("sent-1"), by: copy)
        let draft = SyncEngine.placeholderReplacement(of: row("draft-1"), by: copy)
        let uid = SyncEngine.placeholderReplacement(of: row("499"), by: copy)
        let graphId = SyncEngine.placeholderReplacement(of: row("srv-old"), by: copy)
        let sentMove = Self.replacement(
            of: "a:Sent:sent-1", by: "a:Sent:500", providerId: "500",
            stableIds: StableIds(accountId: "a", old: "sent-1", new: "500"))
        let draftMove = Self.replacement(
            of: "a:Sent:draft-1", by: "a:Sent:500", providerId: "500",
            stableIds: StableIds(accountId: "a", old: "draft-1", new: "500"))
        #expect(sent == sentMove)
        #expect(draft == draftMove)
        #expect(uid == nil)
        #expect(graphId == nil)
    }

    // MARK: - Full sync

    /// IMAP lists a large Sent or Drafts folder by a UID window, which never
    /// judges a placeholder; the server's copy then replaces it as it is stored.
    @Test("A windowed listing that stores the server's copy over a placeholder reports the re-key",
          arguments: [FolderRole.sent, .drafts])
    func windowedListingReportsTheReplacement(role: FolderRole) async throws {
        let f = try Fixture.make(provider: .imap, role: role, path: role == .sent ? "Sent" : "Drafts")
        defer { f.tearDown() }
        let rfc822 = "copy-\(UUID().uuidString.prefix(8))@example.com"
        let placeholder = try f.insertRow("\(role == .sent ? "sent" : "draft")-\(UUID().uuidString)", rfc822: rfc822)
        let provider = MockEmailProvider(staleWindowMode: .uid)
        await provider.setFetchMessagesResult([Self.listed("500", rfc822: rfc822)])

        // Limit 1 with one record: the listing does not span the folder.
        let result = try await SyncEngine.runListing(
            for: f.folder, provider: provider, limit: 1,
            dbPool: PrioritizedDatabase(pool: f.pool)).requireResult()

        let stored = try f.storedIds()
        #expect(stored == [f.headerId("500")], "precondition: the copy replaced the placeholder")
        #expect(result.uidMigratedOldIds.isEmpty, "precondition: stored as new, not remapped")
        let copyId = f.headerId("500")
        let storedCopy = try await f.pool.read { try MessageHeader.fetchOne($0, key: copyId) }
        let copy = try #require(storedCopy)
        let move = Self.replacement(
            of: placeholder.id, by: f.headerId("500"), providerId: "500",
            stableIds: StableIds(from: placeholder, to: copy))
        #expect(result.headerRekeys == [move])
    }

    /// What the user attached to the placeholder belongs to the email, so it
    /// moves to the copy in the listing's own write: the saved chat to the
    /// copy's session (the placeholder's id was its stable id; the copy's is its
    /// Message-ID) naming the copy, and the user's label to the copy's row.
    @Test("The server's copy takes the placeholder's saved chat and user labels")
    func copyTakesThePlaceholdersChatAndLabels() async throws {
        let f = try Fixture.make(provider: .imap, role: .sent, path: "Sent")
        defer { f.tearDown() }
        let rfc822 = "copy-\(UUID().uuidString.prefix(8))@example.com"
        let placeholder = try f.insertRow("sent-\(UUID().uuidString)", rfc822: rfc822)
        let label = UserLabel(accountId: f.accountId, providerLabelId: "keep", name: "Keep", isSystem: false)
        let tag = "pcr-chat-\(UUID().uuidString.prefix(8))"
        try await f.pool.write { db in
            try label.insert(db)
            try MessageUserLabel(messageId: placeholder.id, userLabelId: label.id).insert(db)
            try SavedChatFixture.insert(
                tag: tag, sessionId: SavedChatFixture.sessionId(accountId: f.accountId, stableId: placeholder.stableId),
                namingHeaderId: placeholder.id, db: db)
        }
        let provider = MockEmailProvider(staleWindowMode: .uid)
        await provider.setFetchMessagesResult([Self.listed("500", rfc822: rfc822)])

        _ = try await SyncEngine.runListing(
            for: f.folder, provider: provider, limit: 1,
            dbPool: PrioritizedDatabase(pool: f.pool)).requireResult()

        let storedCopy = try await f.pool.read { try MessageHeader.fetchOne($0, key: f.headerId("500")) }
        let copy = try #require(storedCopy, "precondition: the copy replaced the placeholder")
        let after = try await f.pool.read { db in
            (chat: try SavedChatFixture.read(tag: tag, db: db),
             labels: try MessageUserLabel.filter(Column("userLabelId") == label.id).fetchAll(db).map(\.messageId))
        }
        let chatFollowed = SavedChatFixture.expected(
            sessionId: SavedChatFixture.sessionId(accountId: f.accountId, stableId: copy.stableId),
            namingHeaderId: copy.id)
        #expect(copy.stableId != placeholder.stableId, "precondition: the email's stable id changed")
        #expect(after.chat == chatFollowed)
        #expect(after.labels == [copy.id])
    }

    /// Outlook and Gmail list Sent by date. A listing that spans the folder
    /// judges the placeholder stale and remaps it to the copy by Message-ID.
    @Test("A date-window listing that remaps a placeholder to the server's copy reports the re-key")
    func dateWindowRemapOfAPlaceholderReportsIt() async throws {
        let f = try Fixture.make(provider: .outlook, role: .sent, path: "Sent")
        defer { f.tearDown() }
        let date = Date().addingTimeInterval(-60)
        let rfc822 = "copy-\(UUID().uuidString.prefix(8))@example.com"
        let placeholder = try f.insertRow("sent-\(UUID().uuidString)", rfc822: rfc822, date: date)
        let provider = MockEmailProvider(staleWindowMode: .date)
        await provider.setFetchMessagesResult([Self.listed("srv-copy", rfc822: rfc822, date: date)])

        let result = try await SyncEngine.runListing(
            for: f.folder, provider: provider, limit: 50,
            dbPool: PrioritizedDatabase(pool: f.pool)).requireResult()

        let stored = try f.storedIds()
        #expect(stored == [f.headerId("srv-copy")], "precondition: the copy replaced the placeholder")
        #expect(result.uidMigratedOldIds == [placeholder.messageId], "precondition: the remap leg ran")
        let move = Self.replacement(
            of: placeholder.id, by: f.headerId("srv-copy"), providerId: "srv-copy",
            stableIds: StableIds(accountId: f.accountId, old: placeholder.messageId, new: "srv-copy"))
        #expect(result.headerRekeys == [move])
    }

    /// End to end on the production observer: the listing posts after its
    /// write, and the open detail view names the copy when the sync returns.
    @Test("An open detail view on a placeholder follows the server's copy; another view stays put")
    @MainActor func openDetailFollowsTheCopy() async throws {
        let f = try Fixture.make(provider: .imap, role: .sent, path: "Sent")
        defer { f.tearDown() }
        let rfc822 = "copy-\(UUID().uuidString.prefix(8))@example.com"
        let placeholder = try f.insertRow("sent-\(UUID().uuidString)", rfc822: rfc822)
        let other = try f.insertRow("sent-\(UUID().uuidString)", rfc822: "other-\(UUID().uuidString.prefix(8))@example.com")

        let detail = MessageDetailViewModel(
            messageId: placeholder.id, dbPool: f.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        detail._testSeedMessage(placeholder)
        let bystander = MessageDetailViewModel(
            messageId: other.id, dbPool: f.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        bystander._testSeedMessage(other)

        let provider = MockEmailProvider(staleWindowMode: .uid)
        await provider.setFetchMessagesResult([Self.listed("500", rfc822: rfc822)])
        _ = await SyncEngine().listFolder(f.folder, provider: provider, limit: 1)

        let copyId = f.headerId("500")
        let stored = try f.storedIds()
        #expect(stored == [copyId, other.id], "precondition: the copy replaced the placeholder")
        #expect(detail.messageId == copyId)
        #expect(detail.message?.id == copyId)
        #expect(detail.message?.messageId == "500")
        #expect(bystander.messageId == other.id)
        #expect(bystander.message?.id == other.id)
    }

    // MARK: - Change pass (Outlook)

    /// Once Sent is tracked, the server's copy arrives through the change pass,
    /// which replaces the placeholder as it stores the copy.
    @Test("Outlook's change pass posts the re-key when the server's copy replaces a Sent placeholder")
    func changePassPostsTheReplacement() async throws {
        try await OutlookChangeReadingTests.withWorld { w in
            let sent = OutlookChangeReadingTests.sent
            try await w.foregroundPass()
            try await w.foregroundPass()
            let tracking = try FolderChangeState(raw: w.folder(sent).changeState).tracking
            #expect(tracking, "precondition: Sent is tracked")

            let placeholderId = "sent-\(UUID().uuidString)"
            let rfc822 = "copy-\(UUID().uuidString.prefix(8))@example.com"
            try w.insertRow(placeholderId, in: sent, date: Date())
            let found = try w.row(placeholderId, in: sent)
            let placeholder = try #require(found)
            try await w.pool.write { db in
                var row = placeholder
                row.rfc822MessageId = EmailFilter.normalizeMessageId("<\(rfc822)>")
                try row.update(db)
            }
            w.server.deliver(StatefulExchangeActionServer.Seed(
                rfc822MessageId: rfc822, providerMessageId: "srv-copy", folderId: sent,
                isRead: true, isFlagged: false, receivedAt: Date()))

            let posted = PostedRekeys(accountId: w.accountId)
            try await posted.observing { try await w.delta() }

            let stored = try w.rowIds(in: sent)
            #expect(stored == ["srv-copy"], "precondition: the change pass replaced the placeholder")
            let foundCopy = try w.row("srv-copy", in: sent)
            let copy = try #require(foundCopy)
            let move = Self.replacement(
                of: placeholder.id, by: copy.id, providerId: "srv-copy",
                stableIds: StableIds(accountId: w.accountId, old: placeholderId, new: "srv-copy"))
            #expect(posted.all == [move])
        }
    }

    /// The change pass moves the placeholder's saved chat to the copy in its
    /// own write, as the full sync does.
    @Test("Outlook's change pass moves the Sent placeholder's saved chat to the server's copy")
    func changePassMovesThePlaceholdersChat() async throws {
        try await OutlookChangeReadingTests.withWorld { w in
            let sent = OutlookChangeReadingTests.sent
            try await w.foregroundPass()
            try await w.foregroundPass()
            let tracking = try FolderChangeState(raw: w.folder(sent).changeState).tracking
            #expect(tracking, "precondition: Sent is tracked")

            let placeholderId = "sent-\(UUID().uuidString)"
            let rfc822 = "copy-\(UUID().uuidString.prefix(8))@example.com"
            let tag = "pcr-change-\(UUID().uuidString.prefix(8))"
            let session = SavedChatFixture.sessionId(accountId: w.accountId, stableId: placeholderId)
            try w.insertRow(placeholderId, in: sent, date: Date())
            let found = try w.row(placeholderId, in: sent)
            let placeholder = try #require(found)
            try await w.pool.write { db in
                var row = placeholder
                row.rfc822MessageId = EmailFilter.normalizeMessageId("<\(rfc822)>")
                try row.update(db)
                try SavedChatFixture.insert(
                    tag: tag, sessionId: session, namingHeaderId: placeholder.id, db: db)
            }
            w.server.deliver(StatefulExchangeActionServer.Seed(
                rfc822MessageId: rfc822, providerMessageId: "srv-copy", folderId: sent,
                isRead: true, isFlagged: false, receivedAt: Date()))

            try await w.delta()

            let foundCopy = try w.row("srv-copy", in: sent)
            let copy = try #require(foundCopy, "precondition: the change pass replaced the placeholder")
            let chat = try await w.pool.read { try SavedChatFixture.read(tag: tag, db: $0) }
            let chatFollowed = SavedChatFixture.expected(
                sessionId: SavedChatFixture.sessionId(accountId: w.accountId, stableId: "srv-copy"),
                namingHeaderId: copy.id)
            #expect(chat == chatFollowed)
        }
    }

    /// The same leg also replaces a row that has a real id when the server
    /// lists another copy with its Message-ID. That correlation is weak, so no
    /// open view is re-pointed by it.
    @Test("Outlook's change pass replacing a row with a real id posts nothing")
    func changePassReplacingARealIdPostsNothing() async throws {
        try await OutlookChangeReadingTests.withWorld { w in
            let sent = OutlookChangeReadingTests.sent
            try await w.foregroundPass()
            try await w.foregroundPass()
            let tracking = try FolderChangeState(raw: w.folder(sent).changeState).tracking
            #expect(tracking, "precondition: Sent is tracked")

            let rfc822 = "copy-\(UUID().uuidString.prefix(8))@example.com"
            try w.insertRow("srv-old", in: sent, date: Date())
            let found = try w.row("srv-old", in: sent)
            let old = try #require(found)
            try await w.pool.write { db in
                var row = old
                row.rfc822MessageId = EmailFilter.normalizeMessageId("<\(rfc822)>")
                try row.update(db)
            }
            w.server.deliver(StatefulExchangeActionServer.Seed(
                rfc822MessageId: rfc822, providerMessageId: "srv-new", folderId: sent,
                isRead: true, isFlagged: false, receivedAt: Date()))

            let posted = PostedRekeys(accountId: w.accountId)
            try await posted.observing { try await w.delta() }

            let stored = try w.rowIds(in: sent)
            #expect(stored == ["srv-new"], "precondition: the change pass replaced the stored row")
            #expect(posted.all.isEmpty)
        }
    }

    // MARK: - The detail view

    /// A reply open on the screen shows its parent, still a placeholder, as a
    /// thread bubble. The bubble names the copy once the sync replaced it.
    @Test("A thread bubble on a placeholder follows the server's copy; the opened message stays")
    @MainActor func threadMemberFollowsTheCopy() async throws {
        let f = try Fixture.make(provider: .imap, role: .sent, path: "Sent")
        defer { f.tearDown() }
        let parentRfc822 = "parent-\(UUID().uuidString.prefix(8))@example.com"
        let parent = try f.insertRow("sent-\(UUID().uuidString)", rfc822: parentRfc822)
        let reply = try f.insertRow("501", rfc822: "reply-\(UUID().uuidString.prefix(8))@example.com")

        let detail = MessageDetailViewModel(
            messageId: reply.id, dbPool: f.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        detail._testSeedMessage(reply)
        detail.threadMessages = [parent]

        let copy = try f.insertRow("500", rfc822: parentRfc822)
        try await f.pool.write { db in _ = try MessageHeader.deleteOne(db, key: parent.id) }
        MailPointerMoves.post(MailPointerMoves([
            .row(Self.replacement(of: parent.id, by: copy.id, providerId: "500"))]))

        let members = detail.threadMessages.map(\.id)
        #expect(members == [copy.id])
        #expect(detail.threadMessages.first?.messageId == "500")
        #expect(detail.messageId == reply.id)
        #expect(detail.message?.id == reply.id)
    }

    /// While a preview is open the view changes nothing; the re-key waits for
    /// the preview to close and is applied then, never dropped.
    @Test("A re-key during a preview is applied when the preview closes")
    @MainActor func rekeyWaitsForThePreview() async throws {
        let f = try Fixture.make(provider: .imap, role: .sent, path: "Sent")
        defer {
            PreviewFreezeGate.shared.end()
            f.tearDown()
        }
        let rfc822 = "copy-\(UUID().uuidString.prefix(8))@example.com"
        let placeholder = try f.insertRow("sent-\(UUID().uuidString)", rfc822: rfc822)
        let detail = MessageDetailViewModel(
            messageId: placeholder.id, dbPool: f.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        detail._testSeedMessage(placeholder)

        let copyId = f.headerId("500")
        PreviewFreezeGate.shared.begin()
        MailPointerMoves.post(MailPointerMoves([
            .row(Self.replacement(of: placeholder.id, by: copyId, providerId: "500"))]))
        #expect(detail.messageId == placeholder.id, "nothing changes under the preview")
        #expect(detail.message?.id == placeholder.id)

        PreviewFreezeGate.shared.end()
        try await waitUntil { detail.messageId == copyId }
        #expect(detail.messageId == copyId)
        #expect(detail.message?.id == copyId)
    }

    /// Two posts during one preview, the second moving the row the first moved
    /// to (the copy replaced the placeholder, then the copy was moved). The
    /// view ends on the last row, which exists, not on the one in between.
    @Test("Two chained moves during a preview leave the view on the last row")
    @MainActor func chainedMovesDuringAPreviewEndOnTheLastRow() async throws {
        let f = try Fixture.make(provider: .imap, role: .sent, path: "Sent")
        defer {
            PreviewFreezeGate.shared.end()
            f.tearDown()
        }
        let rfc822 = "chain-\(UUID().uuidString.prefix(8))@example.com"
        let placeholder = try f.insertRow("sent-\(UUID().uuidString)", rfc822: rfc822)
        let detail = MessageDetailViewModel(
            messageId: placeholder.id, dbPool: f.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        detail._testSeedMessage(placeholder)

        let copyId = f.headerId("500")
        let movedId = MessageIdentity.headerId(accountId: f.accountId, folderPath: "Archive", messageId: "88")
        PreviewFreezeGate.shared.begin()
        MailPointerMoves.post(MailPointerMoves([
            .row(Self.replacement(of: placeholder.id, by: copyId, providerId: "500"))]))
        MailPointerMoves.post(MailPointerMoves([.row(HeaderRekeyRecord(
            oldHeaderId: copyId, newHeaderId: movedId, newProviderMessageId: "88",
            newObservedUidValidity: 3, carriesProviderAuthority: true))]))
        #expect(detail.messageId == placeholder.id, "nothing changes under the preview")

        PreviewFreezeGate.shared.end()
        try await waitUntil { detail.messageId == movedId }
        #expect(detail.messageId == movedId)
        #expect(detail.message?.id == movedId)
        #expect(detail.message?.messageId == "88")
    }

    /// The view follows every committed re-key, as the lists do: a provider
    /// move's finish carries the destination's id and epoch.
    @Test("An open detail view follows a move's finish, epoch included")
    @MainActor func detailFollowsAMoveFinish() async throws {
        let f = try Fixture.make(provider: .imap, role: .sent, path: "Sent")
        defer { f.tearDown() }
        let opened = try f.insertRow("601", rfc822: "moved-\(UUID().uuidString.prefix(8))@example.com")
        let detail = MessageDetailViewModel(
            messageId: opened.id, dbPool: f.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        detail._testSeedMessage(opened)

        let destinationId = MessageIdentity.headerId(accountId: f.accountId, folderPath: "Archive", messageId: "77")
        MailPointerMoves.post(MailPointerMoves([.row(HeaderRekeyRecord(
            oldHeaderId: opened.id, newHeaderId: destinationId, newProviderMessageId: "77",
            newObservedUidValidity: 9, carriesProviderAuthority: true))]))

        #expect(detail.messageId == destinationId)
        #expect(detail.message?.id == destinationId)
        #expect(detail.message?.messageId == "77")
        #expect(detail.message?.observedUidValidity == 9)
    }

    /// A view still polling for its body when its row is re-keyed: the re-key
    /// carries the body to the new id (`MessageHeaderRekey.apply`). The poll
    /// reads the view's own id on every tick, so once the view has followed the
    /// record the body shows with no reopen. Without the follow the poll keeps
    /// reading the old id, which no longer exists, for as long as the view lives.
    @Test("A polling detail view shows the body from the re-keyed row on its next tick")
    @MainActor func pollingViewReadsTheRekeyedRow() async throws {
        let f = try Fixture.make(provider: .imap, role: .sent, path: "Sent")
        defer { f.tearDown() }
        let opened = try f.insertRow("701", rfc822: "poll-\(UUID().uuidString.prefix(8))@example.com")
        let detail = MessageDetailViewModel(
            messageId: opened.id, dbPool: f.pool, fetchBodyOverride: { _ in }, observeNotifications: true)
        detail._testSeedMessage(opened)
        detail.startBodyPoll()

        var moved = opened
        moved.id = f.headerId("702")
        moved.messageId = "702"
        moved.observedUidValidity = 9
        let movedRow = moved
        try await f.pool.write { db in
            _ = try MessageHeader.deleteOne(db, key: opened.id)
            try movedRow.insert(db)
            try MessageBody(contentKey: ContentKey(rawValue: movedRow.id), htmlContent: "<p>moved body</p>").insert(db)
        }
        MailPointerMoves.post(MailPointerMoves([.row(HeaderRekeyRecord(
            oldHeaderId: opened.id, newHeaderId: movedRow.id, newProviderMessageId: "702",
            newObservedUidValidity: 9, carriesProviderAuthority: true))]))

        // The poll ticks every 2 s; allow two ticks.
        try await waitUntil(seconds: 5) { detail.messageBody != nil }
        #expect(detail.messageBody?.htmlContent == "<p>moved body</p>")
        #expect(detail.messageId == movedRow.id)
    }
}
