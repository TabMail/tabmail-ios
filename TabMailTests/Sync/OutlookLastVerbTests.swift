/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// Outlook's last verb (PidTagLastVerbExecuted, `Integer 0x1081`): a reply or
/// forward made in Outlook on the web, the desktop or another phone shows its
/// arrow in TabMail (#890). The fake serves the property only to a request that
/// expands it, and refuses `$expand` on a message delta, as Graph does
/// (measured 2026-11-14). Every test asserts the row the user sees.
extension OutlookChangeReadingTests {

    @Test("A reply or forward made on another device shows on a held message, in the Inbox and the Archive")
    func replyElsewhereShowsTheArrow() async throws {
        try await Self.withWorld(seeds: [
            Self.seed("i-1", in: Self.inbox), Self.seed("i-2", in: Self.inbox), Self.seed("a-1", in: Self.archive),
        ]) { w in
            for id in ["i-1", "i-2"] { try w.insertRow(id, in: w.inbox) }
            try w.insertRow("a-1", in: w.archive)
            try await w.baselineAll()

            w.server.setLastVerbFromOtherClient(providerMessageId: "i-1", verb: GraphAPI.lastVerbReplyToSender)
            w.server.setLastVerbFromOtherClient(providerMessageId: "i-2", verb: GraphAPI.lastVerbReplyToAll)
            w.server.setLastVerbFromOtherClient(providerMessageId: "a-1", verb: GraphAPI.lastVerbForward)
            try await w.read()

            #expect(try w.row("i-1", in: w.inbox)?.isReplied == true, "reply to sender")
            #expect(try w.row("i-2", in: w.inbox)?.isReplied == true, "reply to all")
            let forwarded = try #require(try w.row("a-1", in: w.archive))
            #expect(forwarded.isForwarded == true && forwarded.isReplied == false, "a forward is not a reply")
        }
    }

    @Test("A new Inbox message already replied to elsewhere arrives with its arrow")
    func newMessageArrivesReplied() async throws {
        try await Self.withWorld { w in
            try await w.baselineAll()
            w.server.deliver(Self.seed("new-1", in: Self.inbox, daysAgo: 0))
            w.server.setLastVerbFromOtherClient(providerMessageId: "new-1", verb: GraphAPI.lastVerbReplyToSender)
            try await w.read()
            #expect(try w.row("new-1", in: w.inbox)?.isReplied == true)
        }
    }

    /// Measured 2026-11-14: a reply the app sends (Graph sendMail) leaves the
    /// original with no last verb, and the delta reports nothing. The app marks
    /// the original itself; no read of the original without 0x1081 may clear it:
    /// absence of the verb is not "unanswered".
    @Test("A reply the app sent stays marked when the reader reads the original with no last verb",
          arguments: ["changed elsewhere", "re-read in full"])
    func appReplyMarkSurvivesAnOriginalWithNoVerb(path: String) async throws {
        try await Self.withWorld(seeds: [Self.seed("o-1", in: Self.inbox)]) { w in
            try w.insertRow("o-1", in: w.inbox)
            try await w.baselineAll()
            // The app sent a reply: its own mark, which the server never shows.
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE accountId = ?", arguments: [w.accountId])
            }
            if path == "changed elsewhere" {
                w.server.setFlagFromOtherClient(providerMessageId: "o-1", isFlagged: true)
            } else {
                try await w.pool.write { db in
                    var state = FolderChangeState(raw: try Folder.fetchOne(db, key: w.folderId(w.inbox))?.changeState)
                    state.recheck = ["o-1"]
                    try db.execute(sql: "UPDATE folder SET changeState = ? WHERE id = ?",
                                   arguments: [state.encoded, w.folderId(w.inbox)])
                }
            }
            let before = w.batchedIds().count
            try await w.read()
            #expect(w.batchedIds().count > before, "precondition: the original was read by id, with no last verb")
            let row = try #require(try w.row("o-1", in: w.inbox))
            #expect(row.isReplied == true, "the app's own reply mark stays")
            if path == "changed elsewhere" { #expect(row.isFlagged == true, "and the change landed") }
        }
    }

    @Test("A mark the phone holds is never cleared: not by a later forward, not by a read change")
    func markIsNeverCleared() async throws {
        try await Self.withWorld(seeds: [Self.seed("m-1", in: Self.inbox), Self.seed("m-2", in: Self.inbox)]) { w in
            for id in ["m-1", "m-2"] { try w.insertRow(id, in: w.inbox) }
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET isReplied = 1 WHERE accountId = ?", arguments: [w.accountId])
            }
            try await w.baselineAll()

            w.server.setLastVerbFromOtherClient(providerMessageId: "m-1", verb: GraphAPI.lastVerbForward)
            w.server.setReadFromOtherClient(providerMessageId: "m-2", isRead: true)
            try await w.read()

            let forwarded = try #require(try w.row("m-1", in: w.inbox))
            #expect(forwarded.isReplied == true && forwarded.isForwarded == true, "the reply mark stays beside the forward")
            let read = try #require(try w.row("m-2", in: w.inbox))
            #expect(read.isRead == true && read.isReplied == true, "the read change landed and the reply mark stayed")
        }
    }

    @Test("A last verb answered with a throttle never holds the page: it is read again from the re-read list and then shows")
    func throttledVerbReadIsReadAgain() async throws {
        try await Self.withWorld(seeds: [Self.seed("a-1", in: Self.archive)]) { w in
            try w.insertRow("a-1", in: w.archive)
            try await w.baselineAll()
            w.server.setLastVerbFromOtherClient(providerMessageId: "a-1", verb: GraphAPI.lastVerbReplyToSender)
            let tracked = try #require(try w.cursor(w.archive))

            w.server.answerBatchItem(providerMessageId: "a-1", status: 429, body: nil)
            let now = Date()
            try await w.read(now: now)
            #expect(try w.row("a-1", in: w.archive)?.isReplied == false, "precondition: not read this pass")
            #expect(try w.cursor(w.archive)?.next != tracked.next, "the page was passed")
            #expect(try w.recheck(w.archive) == ["a-1"], "listed for a re-read")

            w.server.clearBatchItemAnswers()
            try await w.read(now: now.addingTimeInterval(60))
            #expect(try w.row("a-1", in: w.archive)?.isReplied == true, "the reply shows on the next pass")
            #expect(try w.recheck(w.archive).isEmpty)
        }
    }

    @Test("Last verbs past the allowance never hold a page: a long round of changes still moves, and every reply shows")
    func verbReadsPastTheAllowanceDoNotWedge() async throws {
        let ids = (0..<60).map { String(format: "v-%03d", $0) }
        try await Self.withWorld(seeds: ids.map { Self.seed($0, in: Self.archive) }) { w in
            for id in ids { try w.insertRow(id, in: w.archive) }
            try await w.baselineAll()
            for id in ids { w.server.setLastVerbFromOtherClient(providerMessageId: id, verb: GraphAPI.lastVerbReplyToSender) }
            var now = Date()
            for _ in 0..<30 {
                try await w.read(now: now, requests: 3 + SyncConfig.graphBatchMaxRequests)
                if try ids.allSatisfy({ try w.row($0, in: w.archive)?.isReplied == true }) { break }
                now = now.addingTimeInterval(60)
            }
            #expect(try ids.allSatisfy { try w.row($0, in: w.archive)?.isReplied == true }, "every reply shows")
            #expect(try w.recheck(w.archive).isEmpty)
        }
    }

    @Test("A message whose last verb cannot be read is read again from the re-read list and then shows")
    func unreadableVerbIsReadAgain() async throws {
        try await Self.withWorld(seeds: [Self.seed("a-1", in: Self.archive)]) { w in
            try w.insertRow("a-1", in: w.archive)
            try await w.baselineAll()
            w.server.setLastVerbFromOtherClient(providerMessageId: "a-1", verb: GraphAPI.lastVerbReplyToSender)

            w.server.answerBatchItem(providerMessageId: "a-1", status: 500, body: nil)
            let now = Date()
            try await w.read(now: now)
            #expect(try w.recheck(w.archive) == ["a-1"], "listed for a re-read")

            w.server.clearBatchItemAnswers()
            try await w.read(now: now.addingTimeInterval(60))
            #expect(try w.row("a-1", in: w.archive)?.isReplied == true)
            #expect(try w.recheck(w.archive).isEmpty)
        }
    }

    @Test("A reply shown from elsewhere drops the reply tag, as the phone's own reply does")
    func replyElsewhereDropsTheReplyTag() async throws {
        try await Self.withWorld(seeds: [Self.seed("t-1", in: Self.inbox)]) { w in
            try w.insertRow("t-1", in: w.inbox)
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE messageHeader SET actionTag = ? WHERE accountId = ?",
                               arguments: [ActionTag.reply.rawValue, w.accountId])
            }
            try await w.baselineAll()
            w.server.setLastVerbFromOtherClient(providerMessageId: "t-1", verb: GraphAPI.lastVerbReplyToSender)
            try await w.read()
            let row = try #require(try w.row("t-1", in: w.inbox))
            #expect(row.isReplied == true)
            #expect(row.actionTag == ActionTag.none, "the reply tag is dropped")
        }
    }

    @Test("The full sync's listing shows a reply made elsewhere")
    func listingShowsTheArrow() async throws {
        try await Self.withWorld(seeds: [Self.seed("l-1", in: Self.inbox, daysAgo: 0)]) { w in
            w.server.setLastVerbFromOtherClient(providerMessageId: "l-1", verb: GraphAPI.lastVerbReplyToSender)
            try await w.foregroundPass()
            #expect(try w.row("l-1", in: w.inbox)?.isReplied == true)
        }
    }

    @Test("The listing parses the expanded last verb")
    func listingParsesTheVerb() async throws {
        try await Self.withWorld(seeds: [Self.seed("l-1", in: Self.inbox, daysAgo: 0)]) { w in
            w.server.setLastVerbFromOtherClient(providerMessageId: "l-1", verb: GraphAPI.lastVerbReplyToSender)
            let listed = try await w.provider.fetchMessagesWithObservedEpoch(folder: Self.inbox, limit: 10, offset: 0)
            #expect(listed.messages.first?.isReplied == true)
        }
    }

    @Test("Last verbs never delay paging: after a burst of changes, new Inbox mail lands with the allowance its pages need")
    func verbReadsNeverDelayNewMail() async throws {
        let pageSize = SyncConfig.graphChangeReadPageSize
        let ids = (0..<(pageSize + pageSize / 2)).map { String(format: "r-%03d", $0) }
        try await Self.withWorld(seeds: ids.map { Self.seed($0, in: Self.inbox) }) { w in
            for id in ids { try w.insertRow(id, in: w.inbox) }
            try await w.baselineAll()
            for id in ids { w.server.setReadFromOtherClient(providerMessageId: id, isRead: true) }
            w.server.deliver(Self.seed("zz-new", in: Self.inbox, daysAgo: 0))
            // Exactly the Inbox round's pages: no room for any by-id read.
            let pages = (ids.count + 1 + pageSize - 1) / pageSize
            try await w.read(scope: .inboxOnly, requests: pages)
            #expect(try w.row("zz-new", in: w.inbox) != nil, "the new message landed in the first pass")
            #expect(try w.cursor(w.inbox)?.phase == .tracking)
            #expect(Set(try w.recheck(w.inbox)) == Set(ids + ["zz-new"]), "every unread last verb waits on the re-read list")
        }
    }

    @Test("A baseline reads no last verb")
    func baselineReadsNoVerb() async throws {
        try await Self.withWorld(seeds: [Self.seed("b-1", in: Self.inbox), Self.seed("b-2", in: Self.archive)]) { w in
            w.server.setLastVerbFromOtherClient(providerMessageId: "b-1", verb: GraphAPI.lastVerbReplyToSender)
            try w.insertRow("b-1", in: w.inbox)
            try w.insertRow("b-2", in: w.archive)
            try await w.baselineAll()
            #expect(w.batchedIds().isEmpty, "a baseline lists the folder as it is: no by-id read")
        }
    }

    @Test("A batch item's URL carries the last-verb expand with its spaces encoded")
    func batchItemURLEncodesSpaces() {
        let url = GraphAPI.batchItemURL(path: "/messages/m-1", query: GraphAPI.metadataSelection.withLastVerb.queryParameter)
        #expect(!url.contains(" "))
        #expect(url.hasPrefix("/me/messages/m-1?$select="))
        #expect(url.hasSuffix("&$expand=singleValueExtendedProperties($filter=id%20eq%20'Integer%200x1081')"))
    }

    @Test("The last verb is read only with a request that may expand it, never on a message delta")
    func deltaNeverExpands() async throws {
        try await Self.withWorld(seeds: [Self.seed("a-1", in: Self.archive)]) { w in
            try w.insertRow("a-1", in: w.archive)
            try await w.baselineAll()
            w.server.setLastVerbFromOtherClient(providerMessageId: "a-1", verb: GraphAPI.lastVerbReplyToSender)
            try await w.read()
            let deltas = w.server.http.recordedCalls().filter { $0.url.contains("/messages/delta") }
            #expect(!deltas.isEmpty && deltas.allSatisfy { !$0.url.contains("expand") })
            #expect(w.batchedIds() == ["a-1"], "the changed message was read once, by id")
        }
    }
}
