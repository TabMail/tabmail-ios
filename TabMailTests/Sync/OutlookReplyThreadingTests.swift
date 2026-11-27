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

    /// The Message-IDs a stored row's reference rows name, sorted.
    static func referenceIds(of messageId: String, in path: String, w: World) throws -> [String] {
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
            let beforeLinks = try Self.referenceIds(of: "h-1", in: w.inbox, w: w)
            #expect(beforeLinks == ["old-parent@example.com", "old-root@example.com"],
                    "precondition: the stored chain has its reference rows")

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
            let afterLinks = try Self.referenceIds(of: "h-1", in: w.inbox, w: w)
            #expect(afterLinks == beforeLinks)
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
            try await w.read()

            let batched = w.batchedIds().sorted()
            #expect(batched == ["r-1", "r-2"], "precondition: both by-id reads went in one batch")
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
