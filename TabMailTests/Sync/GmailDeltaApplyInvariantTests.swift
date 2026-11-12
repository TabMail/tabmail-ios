/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// What a user sees after a Gmail change pass, pinned on today's code so a
/// rewrite of the change reader has to keep it.
///
/// Every test drives a public entry, `SyncEngine.performDeltaSync` or one
/// foreground pass (`SyncEngine.sync(account:)` with the full sync due),
/// against a real `GmailProvider` talking to `StatefulGmailActionServer`, and
/// asserts outcomes only: rows, flags, search, unread counts, the action queue
/// and the body queue. No test names an internal of the delta, so the same
/// tests run unchanged against any implementation behind those entries.
///
/// Two kinds:
/// - delta-only tests, each of which fails when the rule it pins is broken;
/// - full-pass tests, which pin what one foreground pass with the full sync
///   due leaves behind. Their folders hold fewer messages than the full
///   sync's listing, so the listing spans each whole folder.
///
/// No test asserts that a change racing the user's own action lands in the
/// SAME pass; those assert convergence once the protection is gone.
///
/// Gmail never reports `isReplied` or an action tag in a message's metadata
/// (`GmailProvider.parseGmailMessage`), so the reply-detect rewrite and the
/// server-tag write-through have no Gmail input that reaches them and are not
/// pinned here.
///
/// `.serialized, .processGlobalState`: these tests swap `AppDatabase.shared`
/// and write `AccountManager.shared`'s recently-completed set, the shared
/// search index and the shared body queue.
@Suite("Gmail change pass: what the user sees", .serialized, .processGlobalState)
struct GmailDeltaApplyInvariantTests {

    static let userLabelId = "Label_1"
    static let userLabelName = "Projects"
    /// Bound on waiting for work the pass leaves running (search removals).
    static let settleTimeoutSeconds: Double = 5

    // MARK: - World

    /// One Gmail account with Inbox, Sent, Drafts, Trash, All Mail and one user
    /// label, a fake mailbox, and ONE provider instance (its user-label catalog
    /// is per instance).
    struct World {
        let pool: DatabasePool
        let accountId: String
        let server: StatefulGmailActionServer
        let provider: GmailProvider
        let folders: [String: Folder]

        func folder(_ path: String) -> Folder { folders[path]! }
        var inbox: Folder { folder("INBOX") }
        var allMail: Folder { folder(GmailProvider.archivePath) }
        var label: Folder { folder(GmailDeltaApplyInvariantTests.userLabelId) }
        var sent: Folder { folder("SENT") }
        var drafts: Folder { folder("DRAFT") }

        func account() throws -> Account {
            try pool.read { db in try Account.fetchOne(db, key: accountId) }!
        }

        /// One production delta pass.
        @discardableResult
        func delta() async throws -> (succeeded: Bool, hadChanges: Bool) {
            try await SyncEngine().performDeltaSync(account: try account(), provider: provider)
        }

        /// One production delta pass that must succeed and leave the cursor at
        /// the mailbox's current history id.
        func completedDelta() async throws {
            let outcome = try await delta()
            #expect(outcome.succeeded, "precondition: the delta pass ran")
            #expect(try account().lastHistoryId == server.currentHistoryId(),
                    "precondition: the pass completed and advanced the cursor")
        }

        /// One production foreground pass with the full sync due.
        func foregroundPassWithFullSyncDue() async throws {
            try await pool.write { db in
                _ = try Account.filter(Column("id") == accountId).updateAll(db,
                    Column("lastSyncedAt").set(to: nil as Date?),
                    Column("lastFullSyncAt").set(to: nil as Date?))
            }
            let engine = SyncEngine()
            await engine.register(
                accountId: accountId, provider: provider,
                workQueue: ProviderWorkQueue(provider: provider, maxConcurrency: 1))
            _ = try await engine.sync(account: try account())
        }

        func historyRequestCount() -> Int {
            server.http.recordedCalls().filter { URL(string: $0.url)?.path.hasSuffix("/history") == true }.count
        }

        func historyStartIds() -> [String] {
            server.http.recordedCalls().compactMap { call -> String? in
                guard let components = URLComponents(string: call.url), components.path.hasSuffix("/history") else { return nil }
                return components.queryItems?.first(where: { $0.name == "startHistoryId" })?.value
            }
        }

        // Reads

        func row(_ messageId: String, in folder: Folder) throws -> MessageHeader? {
            try pool.read { db in
                try MessageHeader.filter(Column("messageId") == messageId && Column("folderId") == folder.id).fetchOne(db)
            }
        }

        func rows(_ messageId: String) throws -> [MessageHeader] {
            try pool.read { db in
                try MessageHeader.filter(Column("messageId") == messageId && Column("accountId") == accountId).fetchAll(db)
            }
        }

        func rows(rfc822 normalized: String, in folder: Folder) throws -> [MessageHeader] {
            try pool.read { db in
                try MessageHeader.filter(Column("rfc822MessageId") == normalized && Column("folderId") == folder.id).fetchAll(db)
            }
        }

        func userLabels(ofHeader headerId: String) throws -> Set<String> {
            try pool.read { db in
                Set(try String.fetchAll(db, sql: """
                    SELECT ul.providerLabelId FROM messageUserLabel mul
                    JOIN userLabel ul ON ul.id = mul.userLabelId
                    WHERE mul.messageId = ?
                    """, arguments: [headerId]))
            }
        }

        func references(ofHeader headerId: String) throws -> Set<String> {
            try pool.read { db in
                Set(try String.fetchAll(db,
                    sql: "SELECT referencedRfc822Id FROM messageReference WHERE messageHeaderId = ?",
                    arguments: [headerId]))
            }
        }

        func pendingOps() throws -> [PendingOperation] {
            try pool.read { db in try PendingOperation.filter(Column("accountId") == accountId).fetchAll(db) }
        }

        func unreadCount(of folder: Folder) throws -> Int {
            try pool.read { db in try Folder.fetchOne(db, key: folder.id)?.unreadCount } ?? -1
        }

        func unreadRows(in folder: Folder) throws -> Int {
            try pool.read { db in
                try MessageHeader.filter(Column("folderId") == folder.id && Column("isRead") == false).fetchCount(db)
            }
        }

        // Writes

        /// A local row as a sync would have left it.
        @discardableResult
        func insertRow(
            _ messageId: String, in folder: Folder, rfc822: String? = nil, date: Date = GmailDeltaApplyInvariantTests.daysAgo(3),
            isRead: Bool = false, isFlagged: Bool = false, summary: String? = nil,
            storedFolderId: String? = nil
        ) throws -> MessageHeader {
            var header = MessageHeader(
                messageId: messageId,
                subject: "Pinned \(messageId)",
                from: "Fixture",
                fromAddress: "sender@example.com",
                to: "recipient@example.com",
                date: date,
                snippet: "pinned fixture",
                folderId: storedFolderId ?? folder.id,
                accountId: accountId,
                folderPath: folder.path,
                isInInbox: folder.role == .inbox,
                providerDate: date
            )
            header.rfc822MessageId = rfc822 ?? GmailDeltaApplyInvariantTests.normalized(messageId)
            header.isRead = isRead
            header.isFlagged = isFlagged
            header.headerComplete = true
            header.summaryBlurb = summary
            let toInsert = header
            try pool.write { db in try toInsert.insert(db) }
            return header
        }

        @discardableResult
        func insertOp(_ type: OperationType, key: String, folder: Folder) throws -> PendingOperation {
            var op = PendingOperation(type: type, messageIds: [key], accountId: accountId, folderPath: folder.path)
            try pool.write { db in try op.insert(db) }
            return op
        }

        func setUnreadCount(_ count: Int, of folder: Folder) throws {
            try pool.write { db in
                try db.execute(sql: "UPDATE folder SET unreadCount = ? WHERE id = ?", arguments: [count, folder.id])
            }
        }
    }

    static func daysAgo(_ days: Double) -> Date {
        Date().addingTimeInterval(-days * 86_400)
    }

    static func rfcValue(_ messageId: String) -> String { "\(messageId)@example.com" }

    /// The stored form of a message's RFC Message-ID, as the Gmail parser keeps it.
    static func normalized(_ messageId: String) -> String {
        EmailFilter.normalizeMessageId("<\(rfcValue(messageId))>")
    }

    static func seed(
        _ id: String, labels: Set<String>, date: Date = daysAgo(3), headers: [String: String] = [:]
    ) -> StatefulGmailActionServer.Seed {
        StatefulGmailActionServer.Seed(
            rfc822MessageId: rfcValue(id), providerMessageId: id, labels: labels,
            internalDate: date, headers: headers)
    }

    static func withWorld(
        seeds: [StatefulGmailActionServer.Seed],
        _ body: (World) async throws -> Void
    ) async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        let accountId = "gdpin-\(UUID().uuidString.prefix(8).lowercased())"
        let server = StatefulGmailActionServer(
            messages: seeds,
            userLabels: [userLabelId: userLabelName],
            systemLabels: ["INBOX", "SENT", "DRAFT", "TRASH"])
        // A full pass takes its cursor from `/profile` (P5, P9, P17).
        server.serveProfile()
        defer {
            server.close()
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        var account = Account(emailAddress: "\(accountId)@example.com", displayName: "Gmail pins", provider: .gmail)
        account.id = accountId
        account.lastHistoryId = server.currentHistoryId()
        account.lastFullSyncAt = Date()
        // Insertion order is the delta's folder order: Inbox first.
        var folderList = [
            Folder(name: "Inbox", path: "INBOX", role: .inbox, accountId: accountId),
            Folder(name: "Sent", path: "SENT", role: .sent, accountId: accountId),
            Folder(name: "Drafts", path: "DRAFT", role: .drafts, accountId: accountId),
            Folder(name: "Trash", path: "TRASH", role: .trash, accountId: accountId),
            Folder(name: "All Mail", path: GmailProvider.archivePath, role: .archive, accountId: accountId),
            Folder(name: userLabelName, path: userLabelId, role: .custom, accountId: accountId),
        ]
        // The user label is a favourite, so the full sync walks it like the
        // system folders (the syncable set: primary, secondary, favourites).
        folderList[folderList.count - 1].isFavorite = true
        let folders = folderList
        let toInsert = account
        try await pool.write { db in
            try toInsert.insert(db)
            for folder in folders { try folder.insert(db) }
        }
        let provider = server.provider()
        // Load the user-label catalog the way the app's folder refresh does, so
        // user labels on fetched messages are recognised.
        _ = try await provider.fetchFolders()
        let world = World(
            pool: pool, accountId: accountId, server: server, provider: provider,
            folders: Dictionary(uniqueKeysWithValues: folders.map { ($0.path, $0) }))
        await AccountManager.shared.clearRecentlyCompletedForTesting()
        try await body(world)
        await UnreadCountManager.shared.awaitIdleForTesting()
    }

    /// Run `body` and wait for it to hold, up to `settleTimeoutSeconds`.
    static func eventually(_ body: () async throws -> Bool) async rethrows -> Bool {
        let deadline = Date().addingTimeInterval(settleTimeoutSeconds)
        while Date() < deadline {
            if try await body() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return try await body()
    }

    static func isSearchable(_ headerId: String) async throws -> Bool {
        let key = ContentKey(rawValue: headerId)
        return try await !SearchIndex.shared.contentKeysMissingFromFTS([key]).contains(key)
    }

    /// Record a completed operation from a synchronous fake-server hook.
    static func recordCompletionBlocking(_ ids: [String]) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await AccountManager.shared.recordRecentlyCompleted(messageIds: ids)
            done.signal()
        }
        done.wait()
    }

    // MARK: - P1: the insert

    @Test("P1: a new message's row carries its header fields, user labels and references; an orphan row is reclaimed, not duplicated")
    func insertCarriesEveryField() async throws {
        let date = Self.daysAgo(2)
        try await Self.withWorld(seeds: [Self.seed("p1-orphan", labels: ["INBOX"])]) { w in
            // A row with the Inbox row's id whose stored folder is one this
            // account's pass does not walk (left by an optimistic move).
            let elsewhere = Folder(name: "Elsewhere", path: "ELSEWHERE", role: .custom, accountId: "gdpin-other")
            try await w.pool.write { db in
                var other = Account(emailAddress: "gdpin-other@example.com", displayName: "Other", provider: .gmail)
                other.id = "gdpin-other"
                try other.insert(db)
                try elsewhere.insert(db)
            }
            try w.insertRow("p1-orphan", in: w.inbox, summary: "kept local summary", storedFolderId: elsewhere.id)
            w.server.addMessage(Self.seed("p1-new", labels: ["INBOX", "UNREAD", "STARRED", Self.userLabelId], date: date, headers: [
                "Subject": "Quarterly plan",
                "From": "Alice Example <alice@example.com>",
                "To": "bob@example.com",
                "Cc": "carol@example.com",
                "Bcc": "dave@example.com",
                "Reply-To": "replies@example.com",
                "In-Reply-To": "<parent-p1@example.com>",
                "References": "<root-p1@example.com> <parent-p1@example.com>",
            ]))
            w.server.applyLabelChange(providerMessageId: "p1-orphan", add: ["STARRED"])
            try await w.completedDelta()

            let row = try #require(try w.row("p1-new", in: w.inbox))
            #expect(row.subject == "Quarterly plan")
            #expect(row.from == "Alice Example")
            #expect(row.fromAddress == "alice@example.com")
            #expect(row.to == "bob@example.com")
            #expect(row.cc == "carol@example.com")
            #expect(row.bcc == "dave@example.com")
            #expect(row.replyTo == "replies@example.com")
            #expect(row.rfc822MessageId == Self.normalized("p1-new"))
            #expect(row.inReplyTo == EmailFilter.normalizeMessageId("<parent-p1@example.com>"))
            #expect(row.references == ["<root-p1@example.com>", "<parent-p1@example.com>"].map(EmailFilter.normalizeMessageId))
            #expect(abs(row.providerDate.timeIntervalSince(date)) < 1, "providerDate is the server's internalDate")
            #expect(row.threadId != nil)
            #expect(row.isRead == false && row.isFlagged == true)
            #expect(try w.userLabels(ofHeader: row.id) == [Self.userLabelId])
            #expect(try w.row("p1-new", in: w.label) != nil, "a user label is also a folder")
            #expect(try w.references(ofHeader: row.id)
                    == Set(["<root-p1@example.com>", "<parent-p1@example.com>"].map(EmailFilter.normalizeMessageId)),
                    "the thread references are stored for thread walking")

            let orphanRows = try w.rows("p1-orphan")
            #expect(orphanRows.count == 1, "the orphan is taken over, not duplicated: \(orphanRows.map(\.id))")
            guard orphanRows.count == 1 else { return }
            #expect(orphanRows[0].folderId == w.inbox.id)
            #expect(orphanRows[0].isFlagged == true)
            #expect(orphanRows[0].summaryBlurb == "kept local summary", "the local row itself was kept")
        }
    }

    // MARK: - P2, P3: removals

    @Test("P2: a message deleted on the server leaves every folder that held it")
    func deletedMessageLeavesEveryFolder() async throws {
        try await Self.withWorld(seeds: [Self.seed("p2-gone", labels: ["INBOX", Self.userLabelId])]) { w in
            try w.insertRow("p2-gone", in: w.inbox)
            try w.insertRow("p2-gone", in: w.label)
            w.server.removeMessage(providerMessageId: "p2-gone")
            try await w.completedDelta()
            let left = try w.rows("p2-gone")
            #expect(left.isEmpty, "rows left: \(left.map(\.id))")
        }
    }

    @Test("P3: a label removed on the server removes the row from that folder only")
    func labelRemovalRemovesOneFolderOnly() async throws {
        try await Self.withWorld(seeds: [Self.seed("p3-msg", labels: ["INBOX", Self.userLabelId])]) { w in
            try w.insertRow("p3-msg", in: w.inbox, summary: "inbox summary")
            try w.insertRow("p3-msg", in: w.label)
            w.server.applyLabelChange(providerMessageId: "p3-msg", remove: [Self.userLabelId])
            try await w.completedDelta()
            #expect(try w.row("p3-msg", in: w.label) == nil)
            let inboxRow = try w.row("p3-msg", in: w.inbox)
            #expect(inboxRow != nil)
            #expect(inboxRow?.summaryBlurb == "inbox summary", "the Inbox row is the same row, untouched")
        }
    }

    // MARK: - P4: pending op shield

    @Test("P4: a pending op on the identity, by message id or by RFC Message-ID alone, keeps the row the server removed")
    func pendingOpOnIdentityKeepsRow() async throws {
        try await Self.withWorld(seeds: [
            Self.seed("p4-by-id", labels: ["INBOX"]),
            Self.seed("p4-by-rfc", labels: ["INBOX"]),
            Self.seed("p4-twin", labels: ["INBOX"]),
        ]) { w in
            for id in ["p4-by-id", "p4-by-rfc", "p4-twin"] { try w.insertRow(id, in: w.inbox) }
            try w.insertOp(.markRead, key: "p4-by-id", folder: w.inbox)
            try w.insertOp(.markRead, key: Self.normalized("p4-by-rfc"), folder: w.inbox)
            for id in ["p4-by-id", "p4-by-rfc", "p4-twin"] {
                w.server.applyLabelChange(providerMessageId: id, remove: ["INBOX"])
            }
            try await w.completedDelta()
            #expect(try w.row("p4-twin", in: w.inbox) == nil, "non-vacuity: the unprotected twin leaves the Inbox")
            #expect(try w.row("p4-by-id", in: w.inbox) != nil, "an op naming the message id owns the row")
            #expect(try w.row("p4-by-rfc", in: w.inbox) != nil, "an op naming only the RFC Message-ID owns the row")
            #expect(try w.pendingOps().count == 2, "the queue is untouched")
        }
    }

    // MARK: - P5: Sent outbox shield (full pass)

    @Test("P5: a Sent row whose send is still in the outbox survives a full pass that does not list it")
    func outboxKeepsSentRow() async throws {
        try await Self.withWorld(seeds: [Self.seed("p5-older-sent", labels: ["SENT"], date: Self.daysAgo(5))]) { w in
            try w.insertRow("p5-older-sent", in: w.sent, date: Self.daysAgo(5), isRead: true)
            try w.insertRow("p5-outbox-local", in: w.sent, date: Self.daysAgo(0.01), isRead: true)
            try w.insertRow("p5-twin-local", in: w.sent, date: Self.daysAgo(0.01), isRead: true)
            let draft = DraftMessage(to: ["recipient@example.com"], subject: "Subject", body: "Body")
            var outbox = OutboxMessage(accountId: w.accountId, draft: draft)
            outbox.status = OutboxStatus.sending.rawValue
            outbox.sentAt = Date()
            outbox.sentMessageId = "<\(Self.rfcValue("p5-outbox-local"))>"
            let outboxRow = outbox
            try await w.pool.write { db in try outboxRow.insert(db) }

            try await w.foregroundPassWithFullSyncDue()

            #expect(try w.row("p5-twin-local", in: w.sent) == nil,
                    "non-vacuity: a Sent row the server does not have and no outbox send names is removed")
            #expect(try w.row("p5-outbox-local", in: w.sent) != nil,
                    "the send is still in the outbox, so its Sent row stays")
            #expect(try w.row("p5-older-sent", in: w.sent) != nil)
        }
    }

    // MARK: - P6, P7: shields read inside the write

    @Test("P6: an operation that completes while the pass fetches the message stops the insert (#106)")
    func completionDuringFetchStopsInsert() async throws {
        try await Self.withWorld(seeds: [
            Self.seed("p6-guarded", labels: ["INBOX"]),
            Self.seed("p6-twin", labels: ["INBOX"]),
        ]) { w in
            // The user archived p6-guarded: its row moved to All Mail and the move is queued.
            try w.insertRow("p6-guarded", in: w.allMail)
            try w.insertRow("p6-twin", in: w.allMail)
            try w.insertOp(.move, key: "p6-guarded", folder: w.inbox)
            // Another client stars both; the server still lists them in the Inbox.
            w.server.applyLabelChange(providerMessageId: "p6-guarded", add: ["STARRED"])
            w.server.applyLabelChange(providerMessageId: "p6-twin", add: ["STARRED"])
            // The move completes while the pass fetches the message.
            let pool = w.pool
            w.server.onGet(providerMessageId: "p6-guarded") {
                Self.recordCompletionBlocking(["p6-guarded"])
                try? pool.write { db in _ = try PendingOperation.deleteAll(db) }
            }
            try await w.completedDelta()
            w.server.onGet(providerMessageId: "p6-guarded", nil)

            #expect(try w.row("p6-twin", in: w.inbox) != nil, "non-vacuity: the server's Inbox label is inserted")
            #expect(try w.row("p6-guarded", in: w.inbox) == nil,
                    "the archive completed during the fetch, so the Inbox row must not come back")
        }
    }

    @Test("P7: an operation queued while the pass fetches the message keeps the row")
    func opQueuedDuringFetchKeepsRow() async throws {
        try await Self.withWorld(seeds: [
            Self.seed("p7-guarded", labels: ["INBOX"]),
            Self.seed("p7-twin", labels: ["INBOX"]),
        ]) { w in
            try w.insertRow("p7-guarded", in: w.inbox)
            try w.insertRow("p7-twin", in: w.inbox)
            w.server.applyLabelChange(providerMessageId: "p7-guarded", remove: ["INBOX"])
            w.server.applyLabelChange(providerMessageId: "p7-twin", remove: ["INBOX"])
            let pool = w.pool
            let accountId = w.accountId
            w.server.onGet(providerMessageId: "p7-guarded") {
                var op = PendingOperation(type: .markRead, messageIds: ["p7-guarded"], accountId: accountId, folderPath: "INBOX")
                try? pool.write { db in try op.insert(db) }
            }
            try await w.completedDelta()
            w.server.onGet(providerMessageId: "p7-guarded", nil)

            #expect(try w.row("p7-twin", in: w.inbox) == nil, "non-vacuity: the unprotected twin leaves the Inbox")
            #expect(try w.row("p7-guarded", in: w.inbox) != nil, "the op queued during the fetch owns the row")
            #expect(try w.pendingOps().count == 1, "the queued op survives the pass")
        }
    }

    // MARK: - P9: one row per RFC Message-ID in Sent and Drafts (full pass)

    @Test("P9: after a full pass Sent and Drafts hold one row per RFC Message-ID")
    func sentAndDraftsDedupByRfc822() async throws {
        let draftRfc = "p9-draft-rfc"
        let sentRfc = "p9-sent-rfc"
        try await Self.withWorld(seeds: [
            StatefulGmailActionServer.Seed(rfc822MessageId: Self.rfcValue(draftRfc), providerMessageId: "p9-draft-server",
                                           labels: ["DRAFT"], internalDate: Self.daysAgo(1)),
            StatefulGmailActionServer.Seed(rfc822MessageId: Self.rfcValue(sentRfc), providerMessageId: "p9-sent-server",
                                           labels: ["SENT"], internalDate: Self.daysAgo(1)),
        ]) { w in
            // The app's own rows, written before the server ids were known,
            // older than anything the listing returns.
            try w.insertRow("p9-draft-local", in: w.drafts, rfc822: Self.normalized(draftRfc), date: Self.daysAgo(30))
            try w.insertRow("p9-sent-local", in: w.sent, rfc822: Self.normalized(sentRfc), date: Self.daysAgo(30))
            // Both are protected from the stale sweep: the draft by a queued op,
            // the sent copy by its send still in the outbox.
            try w.insertOp(.markRead, key: "p9-draft-local", folder: w.drafts)
            var outbox = OutboxMessage(accountId: w.accountId, draft: DraftMessage(to: ["recipient@example.com"], subject: "Subject", body: "Body"))
            outbox.status = OutboxStatus.sending.rawValue
            outbox.sentMessageId = "<\(Self.rfcValue(sentRfc))>"
            let outboxRow = outbox
            try await w.pool.write { db in try outboxRow.insert(db) }

            try await w.foregroundPassWithFullSyncDue()

            let drafts = try w.rows(rfc822: Self.normalized(draftRfc), in: w.drafts)
            #expect(drafts.count == 1, "Drafts rows for one draft: \(drafts.map(\.messageId))")
            #expect(drafts.first?.messageId == "p9-draft-server")
            let sent = try w.rows(rfc822: Self.normalized(sentRfc), in: w.sent)
            #expect(sent.count == 1, "Sent rows for one message: \(sent.map(\.messageId))")
            #expect(sent.first?.messageId == "p9-sent-server")
        }
    }

    // MARK: - P10: AI cache restore

    @Test("P10: a new row gets the summary and tag cached for its message")
    func aiCacheRestoredOnInsert() async throws {
        try await Self.withWorld(seeds: []) { w in
            let rfc = Self.normalized("p10-new")
            let key = try #require(MessageAICache.cacheKey(accountId: w.accountId, folderPath: "INBOX", rfc822MessageId: rfc))
            var cache = MessageAICache(key: key, rfc822MessageId: rfc)
            cache.summaryBlurb = "cached summary"
            cache.actionTag = .archive
            let toInsert = cache
            try await w.pool.write { db in try toInsert.insert(db) }

            w.server.addMessage(Self.seed("p10-new", labels: ["INBOX"]))
            try await w.completedDelta()

            let row = try #require(try w.row("p10-new", in: w.inbox))
            #expect(row.summaryBlurb == "cached summary")
            #expect(row.actionTag == .archive)
        }
    }

    // MARK: - P11: reply discovery

    @Test("P11: a new Sent message marks the message it replies to as replied, and says so")
    func sentInsertMarksParentReplied() async throws {
        try await Self.withWorld(seeds: [Self.seed("p11-parent", labels: ["INBOX"])]) { w in
            let parent = try w.insertRow("p11-parent", in: w.inbox)
            let posted = Mutex<Set<String>>([])
            let token = NotificationCenter.default.addObserver(forName: .messageDataDidChange, object: nil, queue: nil) { note in
                if let id = note.object as? String { _ = posted.withLock { $0.insert(id) } }
            }
            defer { NotificationCenter.default.removeObserver(token) }

            w.server.addMessage(Self.seed("p11-reply", labels: ["SENT"], headers: [
                "In-Reply-To": "<\(Self.rfcValue("p11-parent"))>",
            ]))
            try await w.completedDelta()

            #expect(try w.row("p11-reply", in: w.sent) != nil, "precondition: the reply was inserted")
            #expect(try w.row("p11-parent", in: w.inbox)?.isReplied == true)
            #expect(posted.withLock { $0.contains(parent.id) }, "the parent's change is announced")
        }
    }

    // MARK: - P12: existing rows

    @Test("P12: an existing row takes the server's flags and thread headers, but keeps local flags under a pending flag op")
    func existingRowMerge() async throws {
        let refs = "<root-p12@example.com>"
        try await Self.withWorld(seeds: [
            Self.seed("p12-msg", labels: ["INBOX", "UNREAD"], headers: ["References": refs]),
            Self.seed("p12-guarded", labels: ["INBOX", "UNREAD"]),
        ]) { w in
            var bare = try w.insertRow("p12-msg", in: w.inbox, isRead: false)
            bare.rfc822MessageId = nil
            let toUpdate = bare
            try await w.pool.write { db in try toUpdate.update(db) }
            try w.insertRow("p12-guarded", in: w.inbox, isRead: false)
            try w.insertOp(.markUnread, key: "p12-guarded", folder: w.inbox)

            w.server.applyLabelChange(providerMessageId: "p12-msg", add: ["STARRED"], remove: ["UNREAD"])
            w.server.applyLabelChange(providerMessageId: "p12-guarded", add: ["STARRED"], remove: ["UNREAD"])
            try await w.completedDelta()

            let row = try #require(try w.row("p12-msg", in: w.inbox))
            #expect(row.isRead == true && row.isFlagged == true, "the server's flags")
            #expect(row.rfc822MessageId == Self.normalized("p12-msg"))
            #expect(row.references == [EmailFilter.normalizeMessageId(refs)])
            let guarded = try #require(try w.row("p12-guarded", in: w.inbox))
            #expect(guarded.isRead == false && guarded.isFlagged == false,
                    "a pending flag op keeps the user's flags until it drains")
        }
    }

    // MARK: - P13: search

    @Test("P13: search finds the rows a pass inserts and forgets the rows it removes")
    func searchFollowsRows() async throws {
        try await Self.withWorld(seeds: [Self.seed("p13-gone", labels: ["INBOX"])]) { w in
            let gone = try w.insertRow("p13-gone", in: w.inbox)
            _ = try await SearchIndex.shared.indexHeaders([FTSHeaderRecord(
                contentKey: ContentKey(rawValue: gone.id), headerId: gone.id, messageId: gone.messageId,
                subject: gone.subject, from: gone.from, to: gone.to, cc: gone.cc, bcc: gone.bcc,
                dateMs: Int64(gone.date.timeIntervalSince1970 * 1000), folderId: gone.folderId)])
            #expect(try await Self.isSearchable(gone.id), "precondition: the old row is searchable")

            w.server.removeMessage(providerMessageId: "p13-gone")
            w.server.addMessage(Self.seed("p13-new", labels: ["INBOX"]))
            try await w.completedDelta()

            let new = try #require(try w.row("p13-new", in: w.inbox))
            #expect(try await Self.isSearchable(new.id), "a new row is searchable once the pass returns")
            let forgotten = try await Self.eventually { try await !Self.isSearchable(gone.id) }
            #expect(forgotten, "a removed row leaves search")
            try? await SearchIndex.shared.removeMessagesForAccount(accountId: w.accountId)
        }
    }

    // MARK: - P14: unread counts

    @Test("P14: after a pass the folders' unread counts, which the badge sums, match the rows")
    func unreadCountsMatchRows() async throws {
        try await Self.withWorld(seeds: [
            Self.seed("p14-a", labels: ["INBOX", "UNREAD"]),
            Self.seed("p14-b", labels: ["INBOX", "UNREAD"]),
        ]) { w in
            try w.insertRow("p14-a", in: w.inbox, isRead: false)
            try w.insertRow("p14-b", in: w.inbox, isRead: false)
            try w.setUnreadCount(2, of: w.inbox)
            w.server.applyLabelChange(providerMessageId: "p14-a", remove: ["UNREAD"])
            w.server.applyLabelChange(providerMessageId: "p14-b", remove: ["UNREAD"])
            w.server.addMessage(Self.seed("p14-new", labels: ["INBOX", "UNREAD"]))
            try await w.completedDelta()
            await UnreadCountManager.shared.awaitIdleForTesting()

            #expect(try w.unreadRows(in: w.inbox) == 1, "precondition: one unread row")
            #expect(try w.unreadCount(of: w.inbox) == 1, "the Inbox count the badge sums equals its unread rows")
        }
    }

    // MARK: - P15: replay

    /// Everything the user can see of the account's mail, in a stable order.
    static func visibleState(_ w: World) throws -> [String] {
        try w.pool.read { db in
            let headers = try MessageHeader.filter(Column("accountId") == w.accountId).order(Column("id")).fetchAll(db)
            var lines = headers.map {
                "\($0.id)|\($0.folderId)|\($0.isRead)|\($0.isFlagged)|\($0.rfc822MessageId ?? "-")|\($0.referencesJSON ?? "-")|\($0.summaryBlurb ?? "-")"
            }
            lines += try String.fetchAll(db, sql: """
                SELECT mul.messageId || '>' || ul.providerLabelId FROM messageUserLabel mul
                JOIN userLabel ul ON ul.id = mul.userLabelId ORDER BY 1
                """)
            lines += try String.fetchAll(db, sql:
                "SELECT messageHeaderId || '>' || referencedRfc822Id FROM messageReference ORDER BY 1")
            lines.append("ops=\(try PendingOperation.fetchCount(db))")
            return lines
        }
    }

    @Test("P15: a batch applied twice (the cursor write lost) leaves the same mail")
    func replayIsIdempotent() async throws {
        try await Self.withWorld(seeds: [
            Self.seed("p15-archived", labels: ["INBOX"]),
            Self.seed("p15-gone", labels: ["INBOX"]),
            Self.seed("p15-read", labels: ["INBOX", "UNREAD"]),
        ]) { w in
            for id in ["p15-archived", "p15-gone", "p15-read"] { try w.insertRow(id, in: w.inbox) }
            let start = try w.account().lastHistoryId
            w.server.applyLabelChange(providerMessageId: "p15-archived", remove: ["INBOX"])
            w.server.removeMessage(providerMessageId: "p15-gone")
            w.server.applyLabelChange(providerMessageId: "p15-read", remove: ["UNREAD"])
            w.server.addMessage(Self.seed("p15-new", labels: ["INBOX", Self.userLabelId], headers: [
                "In-Reply-To": "<parent-p15@example.com>",
            ]))
            try await w.completedDelta()
            let once = try Self.visibleState(w)

            // The cursor write was lost: the same history is read and applied again.
            try await w.pool.write { db in
                _ = try Account.filter(Column("id") == w.accountId).updateAll(db, Column("lastHistoryId").set(to: start))
            }
            try await w.completedDelta()
            let twice = try Self.visibleState(w)
            #expect(once == twice, "replaying the batch changed the mail:\nonce:  \(once)\ntwice: \(twice)")
            #expect(try w.row("p15-new", in: w.inbox) != nil, "non-vacuity: the batch inserted")
        }
    }

    // MARK: - P16: body queue and progress

    @Test("P16: new rows are queued for their bodies and the download count is shown")
    func newRowsQueuedForBodies() async throws {
        try await Self.withWorld(seeds: []) { w in
            w.server.addMessage(Self.seed("p16-new", labels: ["INBOX"]))
            // A phase left by an earlier test would satisfy the check below without this pass.
            let phaseBefore = await MainActor.run { () -> SyncPhase? in
                AccountManagerState.shared.clearSyncPhases()
                return AccountManagerState.shared.syncPhase
            }
            #expect(phaseBefore == nil, "no phase is shown before the pass")
            try await w.completedDelta()
            let row = try #require(try w.row("p16-new", in: w.inbox))
            #expect(await ActiveBodyQueue.shared.isQueuedOrInFlight(headerId: row.id), "the new row waits for its body")
            let accountId = w.accountId
            let shown = await Self.eventually {
                await MainActor.run {
                    if case .downloading = AccountManagerState.shared.syncPhase { return true }
                    return false
                }
            }
            #expect(shown, "the download count is published while the pass fetches")
            await MainActor.run { AccountManagerState.shared.setSyncPhase(nil, forAccount: accountId) }
            await ActiveBodyQueue.shared.completeItemForTesting(
                ActiveBodyQueue.Item(headerId: row.id, accountId: row.accountId, folderPath: row.folderPath,
                                     messageId: row.messageId, isInInbox: row.isInInbox),
                shouldRetry: false)
        }
    }

    // MARK: - P17, P18: cursor recovery (#456)

    @Test("P17: an expired cursor recovers end to end: cleared, deltas wait, the full pass takes a new cursor, the next delta reads from it")
    func expiredCursorRecovers() async throws {
        try await Self.withWorld(seeds: [Self.seed("p17-msg", labels: ["INBOX", "UNREAD"])]) { w in
            try w.insertRow("p17-msg", in: w.inbox, isRead: false)
            w.server.applyLabelChange(providerMessageId: "p17-msg", add: ["STARRED"])
            w.server.expireHistory()

            let refused = try await w.delta()
            #expect(refused.succeeded == false, "an expired cursor cannot be read")
            let historyAfterRefusal = w.historyRequestCount()

            let waiting = try await w.delta()
            #expect(waiting.succeeded == false)
            #expect(w.historyRequestCount() == historyAfterRefusal,
                    "with no cursor the next delta waits for the full sync instead of asking again")

            try await w.foregroundPassWithFullSyncDue()
            let resumeId = w.server.currentHistoryId()
            #expect(try w.row("p17-msg", in: w.inbox)?.isFlagged == true, "the full pass shows the server's state")

            w.server.applyLabelChange(providerMessageId: "p17-msg", remove: ["UNREAD"])
            try await w.completedDelta()
            #expect(w.historyStartIds().last == resumeId, "the next delta reads from the cursor the full pass took")
            #expect(try w.row("p17-msg", in: w.inbox)?.isRead == true, "and applies what changed after it")
        }
    }

    @Test("P18: a history longer than one delta takes is handled like an expired one")
    func overLongHistoryRecovers() async throws {
        try await Self.withWorld(seeds: [Self.seed("p18-msg", labels: ["INBOX", "UNREAD"])]) { w in
            try w.insertRow("p18-msg", in: w.inbox, isRead: false)
            for _ in 0..<((GmailAPI.historyMaxChanges / 2) + 1) {
                w.server.applyLabelChange(providerMessageId: "p18-msg", add: ["STARRED"])
                w.server.applyLabelChange(providerMessageId: "p18-msg", remove: ["STARRED"])
            }
            w.server.applyLabelChange(providerMessageId: "p18-msg", remove: ["UNREAD"])

            let refused = try await w.delta()
            #expect(refused.succeeded == false, "the history is too long for one delta")
            let historyAfterRefusal = w.historyRequestCount()
            let waiting = try await w.delta()
            #expect(waiting.succeeded == false)
            #expect(w.historyRequestCount() == historyAfterRefusal, "deltas wait for the full sync")

            try await w.foregroundPassWithFullSyncDue()
            #expect(try w.row("p18-msg", in: w.inbox)?.isRead == true, "the full pass shows the server's state")
            #expect(try w.account().lastHistoryId == w.server.currentHistoryId(), "and takes a cursor deltas can read")
        }
    }

    // MARK: - P19: a shielded change converges

    @Test("P19: a change skipped under a pending op shows one foreground pass after the op drains")
    func shieldedChangeConverges() async throws {
        try await Self.withWorld(seeds: [
            Self.seed("p19-guarded", labels: ["INBOX", "UNREAD"], date: Self.daysAgo(1)),
        ]) { w in
            try w.insertRow("p19-guarded", in: w.inbox, date: Self.daysAgo(1), isRead: false)
            let op = try w.insertOp(.markUnread, key: "p19-guarded", folder: w.inbox)
            w.server.applyLabelChange(providerMessageId: "p19-guarded", add: ["STARRED"], remove: ["UNREAD"])
            try await w.completedDelta()
            #expect(try w.row("p19-guarded", in: w.inbox)?.isFlagged == false, "precondition: the change was skipped")

            // The op drains.
            try await w.pool.write { db in _ = try PendingOperation.deleteOne(db, key: op.id) }
            try await w.foregroundPassWithFullSyncDue()
            let row = try w.row("p19-guarded", in: w.inbox)
            #expect(row?.isFlagged == true && row?.isRead == true, "the server's flags arrive once nothing shields the row")
        }
    }

    // MARK: - P20: reset message data

    @Test("P20: after Reset Message Data the next pass shows the newest mail")
    func resetShowsNewestMail() async throws {
        try await Self.withWorld(seeds: [
            Self.seed("p20-newest", labels: ["INBOX", "UNREAD"], date: Self.daysAgo(0.1)),
            Self.seed("p20-older", labels: ["INBOX"], date: Self.daysAgo(2)),
        ]) { w in
            try w.insertRow("p20-newest", in: w.inbox, date: Self.daysAgo(0.1))
            try w.insertRow("p20-older", in: w.inbox, date: Self.daysAgo(2), isRead: true)
            try await w.pool.write { db in
                _ = try Account.filter(Column("id") == w.accountId).updateAll(db,
                    Column("lastFullSyncAt").set(to: Date()), Column("lastSyncedAt").set(to: nil as Date?))
                try AccountDetailView.resetMessageDataTxn(db, accountId: w.accountId)
            }
            try await SearchIndex.shared.removeMessagesForAccount(accountId: w.accountId)
            #expect(try w.rows("p20-newest").isEmpty, "precondition: the reset cleared the mail")

            // The pass the reset starts: the account as the reset left it.
            let engine = SyncEngine()
            await engine.register(
                accountId: w.accountId, provider: w.provider,
                workQueue: ProviderWorkQueue(provider: w.provider, maxConcurrency: 1))
            _ = try await engine.sync(account: try w.account())

            #expect(try w.row("p20-newest", in: w.inbox) != nil, "the newest mail is back")
            #expect(try w.row("p20-older", in: w.inbox) != nil)
            try? await SearchIndex.shared.removeMessagesForAccount(accountId: w.accountId)
        }
    }
}
