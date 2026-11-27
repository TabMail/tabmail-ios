/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Outlook's threading ids (#1559): Graph has no In-Reply-To or References field;
/// Exchange keeps them as the extended properties `String 0x1042` and
/// `String 0x1039`. The fake serves them only to a request that expands them, as
/// Graph does (measured 2026-11-27), so the change reader's existing by-id read
/// is what threads a new message under the one it answers. A thread and its
/// reference rows are set once, when a row is inserted; the change reader never
/// moves a stored row's chain or thread. Every test asserts the row the user
/// sees, through a real read and the engine's apply.
extension OutlookChangeReadingTests {

    /// The thread of the stored message a reply answers.
    static let parentThread = "thread-parent"

    /// A stored row's thread, as an earlier insert left it.
    static func setThread(_ thread: String, of messageId: String, in path: String, w: World) throws {
        try w.pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET computedThreadId = ? WHERE messageId = ? AND folderId = ?",
                arguments: [thread, messageId, w.folderId(path)])
        }
    }

    /// A stored row's chain and its reference rows, as an earlier insert left them.
    static func setChain(
        inReplyTo: String, references: [String], of messageId: String, in path: String, w: World
    ) throws {
        try w.pool.write { db in
            try db.execute(
                sql: "UPDATE messageHeader SET inReplyTo = ?, referencesJSON = ? WHERE messageId = ? AND folderId = ?",
                arguments: [inReplyTo, MessageHeader.encodeReferences(references), messageId, w.folderId(path)])
            let stored = try MessageHeader
                .filter(Column("messageId") == messageId && Column("folderId") == w.folderId(path)).fetchOne(db)
            guard let header = stored else { return }
            try ThreadUtils.insertMessageReferences(for: header, db: db)
        }
    }

    /// The Message-IDs a stored row's reference rows name, each once, sorted.
    /// `insertMessageReferences` writes In-Reply-To and every References entry,
    /// so a parent the chain also names has two rows.
    static func referenceIds(of messageId: String, in path: String, w: World) throws -> [String] {
        Array(Set(try referenceRows(of: messageId, in: path, w: w))).sorted()
    }

    /// Every reference row of a stored row, duplicates included, sorted.
    static func referenceRows(of messageId: String, in path: String, w: World) throws -> [String] {
        try w.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT r.referencedRfc822Id FROM messageReference r
                JOIN messageHeader h ON h.id = r.messageHeaderId
                WHERE h.messageId = ? AND h.folderId = ?
                ORDER BY r.referencedRfc822Id
                """, arguments: [messageId, w.folderId(path)])
        }
    }

    /// Reads until Sent tracks too (`baselineAll` waits for Inbox and Archive).
    static func baselineWithSent(_ w: World) async throws {
        try await w.baselineAll()
        for _ in 0..<10 {
            if try w.cursor(Self.sent)?.phase == .tracking { return }
            try await w.read()
        }
    }

    @Test("A new Inbox reply threads under the stored message it answers, in the pass that stores it, with no extra request")
    func newInboxReplyThreadsUnderItsParent() async throws {
        try await Self.withWorld(seeds: [Self.seed("p-1", in: Self.archive)]) { w in
            try w.insertRow("p-1", in: w.archive)
            try Self.setThread(Self.parentThread, of: "p-1", in: w.archive, w: w)
            try await w.baselineAll()

            w.server.deliver(Self.seed("r-1", in: Self.inbox, daysAgo: 0))
            w.server.setThreadingIds(
                providerMessageId: "r-1", inReplyTo: "<p-1@example.com>",
                references: "<root@example.com> <p-1@example.com>")
            try await w.read()

            let stored = try w.row("r-1", in: w.inbox)
            let reply = try #require(stored, "the reply is stored in the pass that read it")
            #expect(reply.computedThreadId == Self.parentThread, "the reply joins its parent's thread")
            #expect(reply.inReplyTo == "p-1@example.com")
            #expect(reply.references == ["root@example.com", "p-1@example.com"])
            let links = try Self.referenceIds(of: "r-1", in: w.inbox, w: w)
            #expect(links == ["p-1@example.com", "root@example.com"], "the insert writes the reply's reference rows")
            let batched = w.batchedIds()
            #expect(batched == ["r-1"], "the ids ride the one by-id read the new message already gets")
        }
    }

    @Test("A new reply whose by-id read the allowance cuts is stored in the same pass, grouped by its conversation, and its chain and thread never move")
    func cutVerbReadKeepsConversationGrouping() async throws {
        try await Self.withWorld(seeds: [Self.seed("p-1", in: Self.archive)]) { w in
            try w.insertRow("p-1", in: w.archive)
            try Self.setThread(Self.parentThread, of: "p-1", in: w.archive, w: w)
            try await w.baselineAll()

            w.server.deliver(Self.seed("r-1", in: Self.inbox, daysAgo: 0))
            w.server.setThreadingIds(
                providerMessageId: "r-1", inReplyTo: "<p-1@example.com>",
                references: "<root@example.com> <p-1@example.com>")
            // Exactly the Inbox round's one page: no room for any by-id read.
            let now = Date()
            try await w.read(scope: .inboxOnly, now: now, requests: 1)

            let first = try w.row("r-1", in: w.inbox)
            let stored = try #require(first, "the new message landed in the first pass")
            #expect(stored.computedThreadId == "conversation-r-1@example.com", "grouped by its conversation, as before")
            #expect(stored.inReplyTo == nil)
            #expect(stored.references.isEmpty)
            let recheck = try w.recheck(w.inbox)
            #expect(recheck == ["r-1"], "its unread by-id read waits on the re-read list")

            try await w.read(now: now.addingTimeInterval(60))
            let second = try w.row("r-1", in: w.inbox)
            let reread = try #require(second)
            #expect(reread.computedThreadId == "conversation-r-1@example.com", "a thread is set once, at insert")
            #expect(reread.inReplyTo == nil, "the re-read's chain does not reach the stored row")
            #expect(reread.references.isEmpty && reread.referencesJSON == stored.referencesJSON, "a stored chain stays")
            let links = try Self.referenceIds(of: "r-1", in: w.inbox, w: w)
            #expect(links.isEmpty, "no reference rows are written after the insert")
            let after = try w.recheck(w.inbox)
            #expect(after.isEmpty, "precondition: the re-read ran")
        }
    }

    @Test("A change to a stored message never moves its thread or rewrites its chain or reference rows")
    func heldRowKeepsItsChainAndThread() async throws {
        try await Self.withWorld(seeds: [Self.seed("p-1", in: Self.archive), Self.seed("h-1", in: Self.inbox)]) { w in
            try w.insertRow("p-1", in: w.archive)
            try Self.setThread(Self.parentThread, of: "p-1", in: w.archive, w: w)
            try w.insertRow("h-1", in: w.inbox)
            try Self.setThread("thread-held", of: "h-1", in: w.inbox, w: w)
            try Self.setChain(
                inReplyTo: "old-parent@example.com", references: ["old-root@example.com", "old-parent@example.com"],
                of: "h-1", in: w.inbox, w: w)
            try await w.baselineAll()
            let linked = try Self.referenceIds(of: "h-1", in: w.inbox, w: w)
            #expect(linked == ["old-parent@example.com", "old-root@example.com"],
                    "precondition: the stored chain has its reference rows")
            let beforeLinks = try Self.referenceRows(of: "h-1", in: w.inbox, w: w)

            // The server's chain differs from the stored one.
            w.server.setThreadingIds(
                providerMessageId: "h-1", inReplyTo: "<p-1@example.com>",
                references: "<root@example.com> <p-1@example.com>")
            w.server.setLastVerbFromOtherClient(providerMessageId: "h-1", verb: GraphAPI.lastVerbReplyToSender)
            try await w.read()

            let afterRow = try w.row("h-1", in: w.inbox)
            let held = try #require(afterRow)
            #expect(held.isReplied == true, "precondition: the change was read by id and applied")
            #expect(held.computedThreadId == "thread-held")
            #expect(held.inReplyTo == "old-parent@example.com")
            #expect(held.references == ["old-root@example.com", "old-parent@example.com"])
            let afterLinks = try Self.referenceRows(of: "h-1", in: w.inbox, w: w)
            #expect(afterLinks == beforeLinks, "the reference rows are exactly as they were")
        }
    }

    @Test("New mail in another folder, read by id, threads under the stored message it answers")
    func newArchiveReplyThreadsUnderItsParent() async throws {
        try await Self.withWorld(seeds: [Self.seed("p-1", in: Self.inbox)]) { w in
            try w.insertRow("p-1", in: w.inbox)
            try Self.setThread(Self.parentThread, of: "p-1", in: w.inbox, w: w)
            try await w.baselineAll()

            w.server.deliver(Self.seed("r-2", in: Self.archive, daysAgo: 0))
            w.server.setThreadingIds(providerMessageId: "r-2", inReplyTo: "<p-1@example.com>")
            try await w.read()

            let stored = try w.row("r-2", in: w.archive)
            let reply = try #require(stored)
            #expect(reply.computedThreadId == Self.parentThread)
            #expect(reply.inReplyTo == "p-1@example.com")
        }
    }

    /// Outlook files a forward in the conversation of the email it forwards. A
    /// reply to the forward arrives in that conversation too, so the
    /// conversation alone would group it with the source (ADR-IOS-043).
    @Test("A reply to a forward joins the forward's thread, not its source's, which shares its Outlook conversation",
          arguments: [true, false])
    func replyToForwardJoinsTheForward(namesItsParent: Bool) async throws {
        let shared = "conversation-shared"
        try await Self.withWorld(seeds: [Self.seed("src", in: Self.inbox), Self.seed("fwd", in: Self.inbox)]) { w in
            try w.insertRow("src", in: w.inbox)
            try Self.setThread(shared, of: "src", in: w.inbox, w: w)
            try w.insertRow("fwd", in: w.inbox)
            try Self.setThread("thread-forward", of: "fwd", in: w.inbox, w: w)
            try await w.baselineAll()

            w.server.deliver(Self.seed("r-1", in: Self.inbox, daysAgo: 0))
            w.server.setConversationId(providerMessageId: "r-1", shared)
            w.server.setThreadingIds(
                providerMessageId: "r-1", inReplyTo: namesItsParent ? "<fwd@example.com>" : nil,
                references: "<src@example.com> <fwd@example.com>")
            try await w.read()

            let stored = try w.row("r-1", in: w.inbox)
            let reply = try #require(stored, "the reply is stored in the pass that read it")
            #expect(reply.computedThreadId == "thread-forward", "the reply joins the forward it answers")
            let links = try Self.referenceIds(of: "r-1", in: w.inbox, w: w)
            #expect(links == ["fwd@example.com", "src@example.com"], "the insert writes the reply's reference rows")
        }
    }

    @Test("In a by-id batch with a failed item, the message read still threads under its parent in the same pass")
    func mixedBatchThreadsTheMessageItRead() async throws {
        try await Self.withWorld(seeds: [Self.seed("p-1", in: Self.archive)]) { w in
            try w.insertRow("p-1", in: w.archive)
            try Self.setThread(Self.parentThread, of: "p-1", in: w.archive, w: w)
            try await w.baselineAll()

            for id in ["r-1", "r-2"] {
                w.server.deliver(Self.seed(id, in: Self.inbox, daysAgo: 0))
                w.server.setThreadingIds(providerMessageId: id, inReplyTo: "<p-1@example.com>")
            }
            w.server.answerBatchItem(providerMessageId: "r-2", status: 500, body: nil)
            let batchesBefore = w.server.batchWidths().count
            try await w.read()

            let widths = Array(w.server.batchWidths().dropFirst(batchesBefore))
            #expect(widths == [2], "precondition: both by-id reads went in one batch")
            let batched = w.batchedIds().sorted()
            #expect(batched == ["r-1", "r-2"])
            let readRow = try w.row("r-1", in: w.inbox)
            let read = try #require(readRow)
            #expect(read.computedThreadId == Self.parentThread, "the message read joins its parent's thread")
            #expect(read.inReplyTo == "p-1@example.com")
            let failedRow = try w.row("r-2", in: w.inbox)
            let failed = try #require(failedRow, "the message whose read failed is stored from its delta row")
            #expect(failed.computedThreadId == "conversation-r-2@example.com", "grouped by its conversation, as before")
            let recheck = try w.recheck(w.inbox)
            #expect(recheck == ["r-2"], "its by-id read waits on the re-read list")
        }
    }

    /// Graph documents no order for a batch's answers, and a new message in
    /// another folder whose by-id read fails is read again on a later pass:
    /// each message still threads under the message it answers.
    @Test("By-id reads answered out of order, and one read again on a later pass, each thread under their own parent")
    func batchOrderAndRereadKeepEachChain() async throws {
        try await Self.withWorld(seeds: [Self.seed("p-1", in: Self.inbox), Self.seed("p-2", in: Self.inbox)]) { w in
            try w.insertRow("p-1", in: w.inbox)
            try Self.setThread("thread-one", of: "p-1", in: w.inbox, w: w)
            try w.insertRow("p-2", in: w.inbox)
            try Self.setThread("thread-two", of: "p-2", in: w.inbox, w: w)
            try await w.baselineAll()

            for (id, parent) in [("a-1", "p-1"), ("a-2", "p-2"), ("a-3", "p-1")] {
                w.server.deliver(Self.seed(id, in: Self.archive, daysAgo: 0))
                w.server.setThreadingIds(
                    providerMessageId: id, inReplyTo: "<\(parent)@example.com>",
                    references: "<root-\(parent)@example.com> <\(parent)@example.com>")
            }
            w.server.reverseBatchResponses(true)
            w.server.answerBatchItem(providerMessageId: "a-3", status: 503, body: nil)
            let batchesBefore = w.server.batchWidths().count
            let now = Date()
            try await w.read(now: now)

            let widths = Array(w.server.batchWidths().dropFirst(batchesBefore))
            #expect(widths == [3], "precondition: the three by-id reads went in one batch")
            for (id, parent, thread) in [("a-1", "p-1", "thread-one"), ("a-2", "p-2", "thread-two")] {
                let stored = try w.row(id, in: w.archive)
                let reply = try #require(stored, "\(id) is stored in the pass that read it")
                #expect(reply.computedThreadId == thread, "\(id) joins its own parent's thread")
                #expect(reply.inReplyTo == "\(parent)@example.com")
                #expect(reply.references == ["root-\(parent)@example.com", "\(parent)@example.com"])
            }
            let waiting = try w.row("a-3", in: w.archive)
            #expect(waiting == nil, "precondition: the message whose read failed waits")
            let recheck = try w.recheck(w.archive)
            #expect(recheck == ["a-3"])

            w.server.clearBatchItemAnswers()
            try await w.read(now: now.addingTimeInterval(60))
            let rereadRow = try w.row("a-3", in: w.archive)
            let reread = try #require(rereadRow, "it lands once the server answers")
            #expect(reread.computedThreadId == "thread-one", "the re-read message joins its parent's thread")
            #expect(reread.inReplyTo == "p-1@example.com")
            #expect(reread.references == ["root-p-1@example.com", "p-1@example.com"])
            let links = try Self.referenceIds(of: "a-3", in: w.archive, w: w)
            #expect(links == ["p-1@example.com", "root-p-1@example.com"])
            let after = try w.recheck(w.archive)
            #expect(after.isEmpty)
        }
    }

    /// Graph's sendMail from another client leaves the original with no mark the
    /// delta reports; its copy in Sent names the original in In-Reply-To, as on
    /// Gmail and IMAP.
    @Test("A reply stored in Sent from another client marks the message it answers as replied")
    func sentReplyMarksItsParentReplied() async throws {
        try await Self.withWorld(seeds: [Self.seed("p-1", in: Self.inbox)]) { w in
            try w.insertRow("p-1", in: w.inbox)
            try await Self.baselineWithSent(w)
            let sentPhase = try w.cursor(Self.sent)?.phase
            #expect(sentPhase == .tracking, "precondition: Sent is tracked")

            w.server.deliver(StatefulExchangeActionServer.Seed(
                rfc822MessageId: "s-1@example.com", providerMessageId: "s-1", folderId: Self.sent,
                isRead: true, receivedAt: Date()))
            w.server.setThreadingIds(providerMessageId: "s-1", inReplyTo: "<p-1@example.com>")
            try await w.read()

            let sentRow = try w.row("s-1", in: Self.sent)
            let copy = try #require(sentRow, "precondition: the Sent copy is stored")
            #expect(copy.inReplyTo == "p-1@example.com", "the Sent copy keeps the id of the message it answers")
            let parentRow = try w.row("p-1", in: w.inbox)
            let parent = try #require(parentRow)
            #expect(parent.isReplied == true)
        }
    }

    @Test("The listing parses the expanded threading ids")
    func listingParsesTheThreadingIds() async throws {
        try await Self.withWorld(seeds: [Self.seed("l-1", in: Self.inbox, daysAgo: 0)]) { w in
            w.server.setThreadingIds(
                providerMessageId: "l-1", inReplyTo: "<p-1@example.com>",
                references: "<root@example.com> <p-1@example.com>")
            let listed = try await w.provider.fetchMessagesWithObservedEpoch(folder: Self.inbox, limit: 10, offset: 0)
            let message = try #require(listed.messages.first)
            #expect(message.inReplyTo == "p-1@example.com")
            #expect(message.references == ["root@example.com", "p-1@example.com"])
        }
    }

    /// A full sync's listing reads the threading ids too: a new message it
    /// stores threads under the one it answers, and a stored row's References
    /// are written as on every provider while its thread, In-Reply-To and
    /// reference rows stay.
    @Test("The full listing threads new mail under its parent and writes a stored row's References, keeping its thread")
    func listingThreadsNewMailAndKeepsHeldThreads() async throws {
        try await Self.withWorld(seeds: [
            Self.seed("p-1", in: Self.archive), Self.seed("h-1", in: Self.inbox),
            Self.seed("r-1", in: Self.inbox, daysAgo: 0),
        ]) { w in
            try w.insertRow("p-1", in: w.archive)
            try Self.setThread(Self.parentThread, of: "p-1", in: w.archive, w: w)
            try w.insertRow("h-1", in: w.inbox)
            try Self.setThread("thread-held", of: "h-1", in: w.inbox, w: w)
            for id in ["h-1", "r-1"] {
                w.server.setThreadingIds(
                    providerMessageId: id, inReplyTo: "<p-1@example.com>",
                    references: "<root@example.com> <p-1@example.com>")
            }

            let inboxFolder = try w.folder(w.inbox)
            let outcome = await SyncEngine().listFolder(
                inboxFolder, provider: w.provider, limit: SyncConfig.syncMessageLimit)
            guard case .proven = outcome else {
                Issue.record("precondition: the listing was proven, got \(outcome)")
                return
            }

            let newRow = try w.row("r-1", in: w.inbox)
            let reply = try #require(newRow, "the listing stores the new message")
            #expect(reply.computedThreadId == Self.parentThread, "the new reply joins its parent's thread")
            #expect(reply.inReplyTo == "p-1@example.com")
            #expect(reply.references == ["root@example.com", "p-1@example.com"])
            let links = try Self.referenceIds(of: "r-1", in: w.inbox, w: w)
            #expect(links == ["p-1@example.com", "root@example.com"])

            let heldRow = try w.row("h-1", in: w.inbox)
            let held = try #require(heldRow)
            #expect(held.references == ["root@example.com", "p-1@example.com"], "the listing writes the server's References")
            #expect(held.computedThreadId == "thread-held", "a stored row's thread stays")
            #expect(held.inReplyTo == nil, "and its In-Reply-To")
            let heldLinks = try Self.referenceRows(of: "h-1", in: w.inbox, w: w)
            #expect(heldLinks.isEmpty, "and its reference rows")
        }
    }

    /// Scrolling to older mail (`SyncEngine.fetchOlderMessages`) reads it with
    /// the threading ids, so an older reply threads under the message it answers.
    @Test("An older reply loaded by scrolling threads under the stored message it answers")
    func olderMailScrollThreadsUnderItsParent() async throws {
        try await Self.withWorld(seeds: [
            Self.seed("p-1", in: Self.archive), Self.seed("anchor", in: Self.inbox, daysAgo: 1),
            Self.seed("o-1", in: Self.inbox, daysAgo: 5),
        ]) { w in
            try w.insertRow("p-1", in: w.archive)
            try Self.setThread(Self.parentThread, of: "p-1", in: w.archive, w: w)
            try w.insertRow("anchor", in: w.inbox, date: Self.daysAgo(1))
            w.server.setThreadingIds(
                providerMessageId: "o-1", inReplyTo: "<p-1@example.com>",
                references: "<root@example.com> <p-1@example.com>")

            let engine = SyncEngine()
            await engine.register(
                accountId: w.accountId, provider: w.provider,
                workQueue: ProviderWorkQueue(provider: w.provider, maxConcurrency: 1))
            let inboxFolder = try w.folder(w.inbox)
            let older = try await engine.fetchOlderMessages(folders: [inboxFolder])
            await engine.remove(accountId: w.accountId)
            #expect(older.inserted >= 1, "precondition: the scroll loaded older mail")

            let loaded = try w.row("o-1", in: w.inbox)
            let reply = try #require(loaded, "the scroll stored the older reply")
            #expect(reply.computedThreadId == Self.parentThread, "the older reply joins its parent's thread")
            #expect(reply.inReplyTo == "p-1@example.com")
            #expect(reply.references == ["root@example.com", "p-1@example.com"])
            let links = try Self.referenceIds(of: "o-1", in: w.inbox, w: w)
            #expect(links == ["p-1@example.com", "root@example.com"])
        }
    }

    /// The notification extension reads a new message by id with the threading
    /// ids (`OutlookNSEClient.fetchSingleMessage`), stages them, and the merge
    /// into the app's store (`NSEDataBridge.insertNewHeaderFromStaging`) threads
    /// a reply to a forward under the forward, not under its source, which
    /// shares its Outlook conversation.
    @Test("A reply the notification extension stages joins the forward it answers when merged")
    func notificationStagedReplyJoinsTheForward() async throws {
        let accountId = "nse-outlook-" + UUID().uuidString
        let store = ProviderCredentialStore.shared
        _ = try store.install(accountId: accountId, tokens: .init(
            accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
            expiresAt: Date().addingTimeInterval(3_600)))
        defer { try? store.remove(accountId: accountId) }
        let server = StatefulExchangeActionServer(messages: [Self.seed("r-1", in: Self.inbox, daysAgo: 0)])
        defer { server.close() }
        let shared = "conversation-shared"
        server.setConversationId(providerMessageId: "r-1", shared)
        server.setThreadingIds(
            providerMessageId: "r-1", inReplyTo: "<fwd@example.com>",
            references: "<src@example.com> <fwd@example.com>")

        let fetched = await AuthedHTTP.$sessionOverride.withValue(server.http.session) {
            await OutlookNSEClient.fetchSingleMessage(
                messageId: "r-1", accessToken: "", refreshToken: nil, accountId: accountId)
        }
        let meta = try #require(fetched, "the extension read the message")
        #expect(meta.inReplyTo == "fwd@example.com")
        #expect(meta.references == ["src@example.com", "fwd@example.com"])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("nse_staging.sqlite").path
        #expect(AppDatabase.createNSEStagingDB(atPath: path))
        let queue = try DatabaseQueue(path: path)
        defer { TestDatabaseTeardown.closeThenUnlinkNow(queue: queue, directory: dir) }
        NSEStagingDB.ensureObservedUidValidityColumn(db: queue)
        NSEStagingDB.ensureProviderDateColumn(db: queue)
        NSEStagingDB.stageHeader(
            db: queue, accountId: accountId, accountEmail: "user@example.com", provider: "outlook",
            message: meta, historyId: "1")
        let stagedMessage = try Self.stagedMessage(queue, id: "\(accountId):r-1")
        let staged = try #require(stagedMessage, "the extension staged the message")

        let main = try TestDatabase.make()
        try TestDatabase.insertAccount(main, id: accountId, email: "user@example.com", provider: .outlook)
        try TestDatabase.insertFolder(main, name: "Inbox", path: Self.inbox, role: .inbox, accountId: accountId)
        for (id, thread) in [("src", shared), ("fwd", "thread-forward")] {
            let header = try TestDatabase.insertMessageHeader(
                main, messageId: id, folderId: "\(accountId):\(Self.inbox)", accountId: accountId,
                folderPath: Self.inbox, rfc822MessageId: "\(id)@example.com")
            let headerRowId = header.id
            try await main.write { db in
                try db.execute(sql: "UPDATE messageHeader SET computedThreadId = ? WHERE id = ?",
                               arguments: [thread, headerRowId])
            }
        }
        let inserted = try Self.mergeStaged(staged, into: main)
        #expect(inserted, "precondition: the merge inserted the reply")

        let headerId = MessageIdentity.headerId(
            accountId: accountId, folderPath: staged.folderPath, messageId: staged.messageId)
        let mergedRow = try await main.read { db in try MessageHeader.fetchOne(db, key: headerId) }
        let reply = try #require(mergedRow)
        #expect(reply.computedThreadId == "thread-forward", "the reply joins the forward it answers")
        #expect(reply.inReplyTo == "fwd@example.com")
        #expect(reply.references == ["src@example.com", "fwd@example.com"])
        let linkRows = try await main.read { db in
            try String.fetchAll(db, sql: "SELECT referencedRfc822Id FROM messageReference WHERE messageHeaderId = ?",
                                arguments: [headerId])
        }
        let links = Set(linkRows)
        #expect(links == ["fwd@example.com", "src@example.com"], "the merge writes the reply's reference rows")
    }

    /// The message the extension staged. Synchronous, so GRDB's synchronous read
    /// runs: a `Row` is not `Sendable` and cannot leave an async read.
    static func stagedMessage(_ queue: DatabaseQueue, id: String) throws -> NSEDataBridge.StagedMessage? {
        let row = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM nse_processed_message WHERE id = ?", arguments: [id])
        }
        return row.map { NSEDataBridge.StagedMessage(row: $0) }
    }

    /// The main app's merge of a staged message. Synchronous, so GRDB's synchronous
    /// write runs: `StagedMessage` is not `Sendable`.
    static func mergeStaged(_ staged: NSEDataBridge.StagedMessage, into main: DatabaseQueue) throws -> Bool {
        try main.write { db in
            var ftsBatch: [NSEDataBridge.NSEFTSBodyItem] = []
            return try NSEDataBridge.insertNewHeaderFromStaging(staged, db: db, ftsBatch: &ftsBatch)
        }
    }

    /// The fake's own contract, which every test above leans on: Graph serves an
    /// extended property only to a request whose expand names it.
    @Test("The Graph fake serves exactly the threading ids a request expands")
    func fakeServesOnlyTheExpandedThreadingIds() throws {
        var message = StatefulExchangeActionServer.Message(
            rfc822MessageId: "f-1@example.com", providerMessageId: "f-1", folderId: Self.inbox,
            isRead: false, isFlagged: false, receivedAt: Date())
        message.extendedProperties = ["String 0x1042": "<p-1@example.com>", "String 0x1039": "<p-1@example.com>"]
        func served(_ url: String) -> Set<String> {
            let row = StatefulExchangeActionServer.graphRow(
                message, expanding: StatefulExchangeActionServer.expandedPropertyIds(url))
            let properties = row["singleValueExtendedProperties"] as? [[String: String]] ?? []
            return Set(properties.compactMap { $0["id"] })
        }
        let base = "https://graph.microsoft.com/v1.0/me/messages/f-1?$select=id"
        let none = served(base)
        #expect(none.isEmpty)
        let one = served(base + "&$expand=singleValueExtendedProperties($filter=id eq 'String 0x1042')")
        #expect(one == ["String 0x1042"])
        let both = served(base + "&\(GraphAPI.extendedPropertiesExpandParameter)")
        #expect(both == ["String 0x1042", "String 0x1039"])
    }
}

extension OutlookCatchUpTests {

    /// The older-mail walk and the catch-up store what they read with
    /// `fetchSingleBackfill`, which expands the threading ids too (#1559).
    @Test("An old reply the catch-up loads threads under the stored message it answers")
    func caughtUpReplyThreadsUnderItsParent() async throws {
        let c = Clock()
        try await Self.withWorld(seeds: [
            Self.seed("p-1", in: Self.archive, at: c.daysAgo(2)), Self.seed("o-1", in: Self.archive, at: c.daysAgo(400)),
        ]) { w, engine in
            try w.insertRow("p-1", in: w.archive, date: c.daysAgo(2))
            try R.setThread(R.parentThread, of: "p-1", in: w.archive, w: w)
            w.server.setThreadingIds(
                providerMessageId: "o-1", inReplyTo: "<p-1@example.com>",
                references: "<root@example.com> <p-1@example.com>")
            // The user answered it in another client before TabMail saw it.
            w.server.setLastVerbAsDelivered(providerMessageId: "o-1", verb: GraphAPI.lastVerbReplyToSender)
            try await w.baselineAll()
            let early = try w.row("o-1", in: w.archive)
            #expect(early == nil, "precondition: the baseline does not insert below the held range")

            let listed = try await Self.untilListed(w, engine, w.archive)
            #expect(listed != nil, "precondition: the catch-up listed the folder")

            let loaded = try w.row("o-1", in: w.archive)
            let reply = try #require(loaded, "the catch-up loaded the old reply")
            #expect(reply.computedThreadId == R.parentThread, "the old reply joins its parent's thread")
            #expect(reply.inReplyTo == "p-1@example.com")
            #expect(reply.references == ["root@example.com", "p-1@example.com"])
            #expect(reply.isReplied == true, "the same read carries its last verb: the reply made elsewhere shows")
        }
    }
}

extension SendReplyMarksTests {

    /// The whole path on Outlook, where Graph's sendMail from another client
    /// leaves no replied mark the delta reports: the user replies on the web
    /// while TabMail's reply waits (it failed), then discards TabMail's reply.
    /// The web reply's copy in Sent, read with its threading ids, tells.
    @Test("Outlook: a reply sent on the web while TabMail's waited keeps the original replied when TabMail's is discarded")
    func outlookWebReplyWhileTheSendWaited() async throws {
        typealias R = OutlookChangeReadingTests
        try await R.withWorld(seeds: [R.seed("o-1", in: R.inbox)]) { w in
            try w.insertRow("o-1", in: w.inbox)
            try await R.baselineWithSent(w)
            let sentPhase = try w.cursor(R.sent)?.phase
            #expect(sentPhase == .tracking, "precondition: Sent is tracked")
            let stored = try w.row("o-1", in: w.inbox)
            let original = try #require(stored)
            try await Self.tagReply(w.pool, headerId: original.id)
            let before = try Self.marks(w.pool, headerId: original.id)
            let queued = try await Self.queueAndCheckHeld(
                pool: w.pool, accountId: w.accountId, original: original, isForward: false, before: before)
            let replied = Self.held(before: before, isForward: false)

            w.server.deliver(StatefulExchangeActionServer.Seed(
                rfc822MessageId: "web-reply@example.com", providerMessageId: "web-reply", folderId: R.sent,
                isRead: true, receivedAt: Date()))
            w.server.setThreadingIds(
                providerMessageId: "web-reply", inReplyTo: "<o-1@example.com>", references: "<o-1@example.com>")
            try await w.read()
            let copyRow = try w.row("web-reply", in: R.sent)
            let copy = try #require(copyRow, "precondition: the web reply's copy synced")
            #expect(copy.inReplyTo == "o-1@example.com", "the copy keeps the id of the message it answers")

            let cancelled = try await Self.cancel(pool: w.pool, outboxId: queued.outboxId, failedFirst: true)
            #expect(cancelled.revertedOriginalHeaderId == nil, "the web reply keeps what Send changed")
            let tags = try Self.queuedTags(w.pool)
            #expect(tags.isEmpty, "no Reply is restored: \(tags)")
            let afterRemoval = try Self.marks(w.pool, headerId: original.id)
            #expect(afterRemoval == replied, "replied, its Reply tag cleared: \(afterRemoval), want \(replied)")
        }
    }
}
