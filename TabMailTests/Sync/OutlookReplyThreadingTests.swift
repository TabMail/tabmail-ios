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
/// is what threads a new message under the one it answers. A thread is set once,
/// when a row is inserted; a stored row's chain and thread never move. Every test
/// asserts the row the user sees, through a real read and the engine's apply.
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
            let batched = w.batchedIds()
            #expect(batched == ["r-1"], "the ids ride the one by-id read the new message already gets")
        }
    }

    @Test("A new reply whose by-id read the allowance cuts is stored in the same pass, grouped by its conversation, and its thread never moves")
    func cutVerbReadKeepsConversationGrouping() async throws {
        try await Self.withWorld(seeds: [Self.seed("p-1", in: Self.archive)]) { w in
            try w.insertRow("p-1", in: w.archive)
            try Self.setThread(Self.parentThread, of: "p-1", in: w.archive, w: w)
            try await w.baselineAll()

            w.server.deliver(Self.seed("r-1", in: Self.inbox, daysAgo: 0))
            w.server.setThreadingIds(providerMessageId: "r-1", inReplyTo: "<p-1@example.com>")
            // Exactly the Inbox round's one page: no room for any by-id read.
            let now = Date()
            try await w.read(scope: .inboxOnly, now: now, requests: 1)

            let first = try w.row("r-1", in: w.inbox)
            let stored = try #require(first, "the new message landed in the first pass")
            #expect(stored.computedThreadId == "conversation-r-1@example.com", "grouped by its conversation, as before")
            #expect(stored.inReplyTo == nil)
            let recheck = try w.recheck(w.inbox)
            #expect(recheck == ["r-1"], "its unread by-id read waits on the re-read list")

            try await w.read(now: now.addingTimeInterval(60))
            let second = try w.row("r-1", in: w.inbox)
            let reread = try #require(second)
            #expect(reread.computedThreadId == "conversation-r-1@example.com", "a thread is set once, at insert")
            #expect(reread.inReplyTo == nil && reread.referencesJSON == stored.referencesJSON, "a stored chain stays")
            let after = try w.recheck(w.inbox)
            #expect(after.isEmpty, "precondition: the re-read ran")
        }
    }

    @Test("A change to a stored message never moves its thread or rewrites its chain")
    func heldRowKeepsItsChainAndThread() async throws {
        try await Self.withWorld(seeds: [Self.seed("p-1", in: Self.archive), Self.seed("h-1", in: Self.inbox)]) { w in
            try w.insertRow("p-1", in: w.archive)
            try Self.setThread(Self.parentThread, of: "p-1", in: w.archive, w: w)
            try w.insertRow("h-1", in: w.inbox)
            try Self.setThread("thread-held", of: "h-1", in: w.inbox, w: w)
            try await w.baselineAll()
            let beforeRow = try w.row("h-1", in: w.inbox)
            let before = try #require(beforeRow)

            w.server.setThreadingIds(
                providerMessageId: "h-1", inReplyTo: "<p-1@example.com>", references: "<p-1@example.com>")
            w.server.setLastVerbFromOtherClient(providerMessageId: "h-1", verb: GraphAPI.lastVerbReplyToSender)
            try await w.read()

            let afterRow = try w.row("h-1", in: w.inbox)
            let held = try #require(afterRow)
            #expect(held.isReplied == true, "precondition: the change was read by id and applied")
            #expect(held.computedThreadId == "thread-held")
            #expect(held.inReplyTo == before.inReplyTo)
            #expect(held.referencesJSON == before.referencesJSON)
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

    /// Graph's sendMail from another client leaves the original with no mark the
    /// delta reports; its copy in Sent names the original in In-Reply-To, as on
    /// Gmail and IMAP.
    @Test("A reply stored in Sent from another client marks the message it answers as replied")
    func sentReplyMarksItsParentReplied() async throws {
        try await Self.withWorld(seeds: [Self.seed("p-1", in: Self.inbox)]) { w in
            try w.insertRow("p-1", in: w.inbox)
            try await w.baselineAll()
            let sentState = try w.folder(Self.sent).changeState
            #expect(FolderChangeState(raw: sentState).tracking, "precondition: Sent is tracked")

            w.server.deliver(StatefulExchangeActionServer.Seed(
                rfc822MessageId: "s-1@example.com", providerMessageId: "s-1", folderId: Self.sent,
                isRead: true, receivedAt: Date()))
            w.server.setThreadingIds(providerMessageId: "s-1", inReplyTo: "<p-1@example.com>")
            try await w.read()

            let sentRow = try w.row("s-1", in: Self.sent)
            #expect(sentRow != nil, "precondition: the Sent copy is stored")
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
}
