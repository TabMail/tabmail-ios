/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("ThreadGroupBuilder")
struct ThreadGroupBuilderTests {

    // MARK: - Helpers

    /// Create a MessageSnapshot with optional thread/reply fields.
    /// computedThreadId is the primary grouping signal (assigned at insert time).
    private func makeSnapshot(
        messageId: String = "1",
        subject: String = "Test",
        from: String = "sender@test.com",
        date: Date = Date(),
        threadId: String? = nil,
        computedThreadId: String = "",
        rfc822MessageId: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        isRead: Bool = true,
        actionTag: ActionTag? = nil
    ) -> MessageSnapshot {
        var header = MessageHeader(
            messageId: messageId,
            subject: subject,
            from: from,
            fromAddress: from,
            to: "recipient@test.com",
            date: date,
            snippet: "snippet",
            folderId: "acct1:INBOX",
            accountId: "acct1",
            folderPath: "INBOX",
            isInInbox: true
        )
        header.threadId = threadId
        header.computedThreadId = computedThreadId
        header.rfc822MessageId = rfc822MessageId
        header.inReplyTo = inReplyTo
        header.referencesJSON = MessageHeader.encodeReferences(references)
        header.isRead = isRead
        header.actionTag = actionTag
        if let tag = actionTag {
            header.tagSortOrder = tag.sortOrder
        }
        return MessageSnapshot(from: header)
    }

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Tests

    @Test("Empty messages returns empty groups")
    func emptyMessages() {
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [])
        #expect(result.isEmpty)
    }

    @Test("Single message returns single group with memberCount 1")
    func singleMessage() {
        let snap = makeSnapshot(messageId: "m1", computedThreadId: "thread-1")
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [snap])
        #expect(result.count == 1)
        #expect(result[0].memberCount == 1)
        #expect(result[0].representative.id == snap.id)
        #expect(result[0].isThread == false)
    }

    @Test("Two unrelated messages produce two groups")
    func twoUnrelatedMessages() {
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "thread-1")
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60), computedThreadId: "thread-2")
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2])
        #expect(result.count == 2)
        #expect(result[0].memberCount == 1)
        #expect(result[1].memberCount == 1)
    }

    @Test("Two messages with same computedThreadId grouped into one")
    func sameComputedThreadId() {
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "thread-abc")
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60), computedThreadId: "thread-abc")
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2])
        #expect(result.count == 1)
        #expect(result[0].memberCount == 2)
        #expect(result[0].isThread == true)
    }

    @Test("Three messages in same thread grouped by computedThreadId")
    func threeMessageThread() {
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "thread-1")
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60), computedThreadId: "thread-1")
        let s3 = makeSnapshot(messageId: "m3", date: baseDate.addingTimeInterval(120), computedThreadId: "thread-1")
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2, s3])
        #expect(result.count == 1)
        #expect(result[0].memberCount == 3)
    }

    @Test("Empty computedThreadId falls back to message id — separate groups")
    func emptyComputedThreadIdFallback() {
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "")
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60), computedThreadId: "")
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2])
        #expect(result.count == 2)
    }

    @Test("Groups sorted by most recent date descending")
    func sortedByDateDescending() {
        let older = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "t1")
        let newer = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(3600), computedThreadId: "t2")
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [older, newer])
        #expect(result.count == 2)
        #expect(result[0].representative.id == newer.id)
        #expect(result[1].representative.id == older.id)
    }

    @Test("allSenders deduplication — same sender appears once")
    func senderDeduplication() {
        let s1 = makeSnapshot(messageId: "m1", from: "alice@test.com", date: baseDate, computedThreadId: "t1")
        let s2 = makeSnapshot(messageId: "m2", from: "alice@test.com", date: baseDate.addingTimeInterval(60), computedThreadId: "t1")
        let s3 = makeSnapshot(messageId: "m3", from: "bob@test.com", date: baseDate.addingTimeInterval(120), computedThreadId: "t1")
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2, s3])
        #expect(result.count == 1)
        // Most recent first: bob, then alice
        #expect(result[0].allSenders == ["bob@test.com", "alice@test.com"])
    }

    @Test("hasUnread true when any member is unread")
    func hasUnreadWhenAnyUnread() {
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "t1", isRead: true)
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60), computedThreadId: "t1", isRead: false)
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2])
        #expect(result.count == 1)
        #expect(result[0].hasUnread == true)
    }

    @Test("hasUnread false when all members are read")
    func noUnreadWhenAllRead() {
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "t1", isRead: true)
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60), computedThreadId: "t1", isRead: true)
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2])
        #expect(result[0].hasUnread == false)
    }

    @Test("threadTag picks lowest sortOrder")
    func threadTagLowestSortOrder() {
        // reply=0, none=1, archive=2, delete=3
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "t1", actionTag: .archive)
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60), computedThreadId: "t1", actionTag: .reply)
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2])
        #expect(result[0].threadTag == .reply)
    }

    @Test("Members sorted by date descending within group")
    func membersSortedByDateDescending() {
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "t1")
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(120), computedThreadId: "t1")
        let s3 = makeSnapshot(messageId: "m3", date: baseDate.addingTimeInterval(60), computedThreadId: "t1")
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2, s3])
        #expect(result[0].members[0].id == s2.id)
        #expect(result[0].members[1].id == s3.id)
        #expect(result[0].members[2].id == s1.id)
    }

    @Test("Large group (10+ messages) works correctly")
    func largeGroup() {
        let messages = (0..<15).map { i in
            makeSnapshot(
                messageId: "m\(i)",
                from: "sender\(i % 3)@test.com",
                date: baseDate.addingTimeInterval(Double(i) * 60),
                computedThreadId: "big-thread"
            )
        }
        let result = ThreadGroupBuilder.buildDisplayGroups(from: messages)
        #expect(result.count == 1)
        guard let group = result.first, let lastMessage = messages.last else { return }
        #expect(group.memberCount == 15)
        // 3 unique senders
        #expect(group.allSenders.count == 3)
        // Representative is the most recent
        #expect(group.representative.id == lastMessage.id)
    }

    @Test("Stable sort tie-break by group id when dates are equal")
    func stableSortTieBreak() {
        let s1 = makeSnapshot(messageId: "m_aaa", date: baseDate, computedThreadId: "t_aaa")
        let s2 = makeSnapshot(messageId: "m_zzz", date: baseDate, computedThreadId: "t_zzz")
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [s2, s1])
        // Same date → sorted by id ascending
        #expect(result[0].id < result[1].id)
    }

    @Test("threadTag nil when no members have tags")
    func threadTagNilWhenNoTags() {
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "t1")
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60), computedThreadId: "t1")
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2])
        #expect(result[0].threadTag == nil)
    }

    @Test("Gmail messages with same computedThreadId grouped even without header chain")
    func gmailComputedThreadId() {
        // Gmail: computedThreadId = native threadId, no inReplyTo/references needed
        let s1 = makeSnapshot(messageId: "m1", date: baseDate, computedThreadId: "19d25dc45aff7666")
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60), computedThreadId: "19d25dc45aff7666")
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2])
        #expect(result.count == 1)
        #expect(result[0].memberCount == 2)
    }

    @Test("IMAP messages with same computedThreadId grouped (chain-walk resolved at insert time)")
    func imapComputedThreadId() {
        // IMAP: computedThreadId was computed at insert time from chain-walking
        // Both messages adopted the same root rfc822MessageId as their computedThreadId
        let s1 = makeSnapshot(messageId: "m1", date: baseDate,
                              computedThreadId: "original@mail.example.com",
                              rfc822MessageId: "original@mail.example.com")
        let s2 = makeSnapshot(messageId: "m2", date: baseDate.addingTimeInterval(60),
                              computedThreadId: "original@mail.example.com",
                              rfc822MessageId: "reply@mail.example.com",
                              inReplyTo: "original@mail.example.com")
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [s1, s2])
        #expect(result.count == 1)
        #expect(result[0].memberCount == 2)
    }

    @Test("Mixed providers: different computedThreadIds stay separate")
    func mixedProvidersSeparate() {
        let gmail = makeSnapshot(messageId: "g1", date: baseDate, computedThreadId: "gmail-thread-1")
        let imap = makeSnapshot(messageId: "i1", date: baseDate.addingTimeInterval(60), computedThreadId: "some-rfc822@imap.com")
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [gmail, imap])
        #expect(result.count == 2)
    }

    // MARK: - Triage mode sort

    @Test("Triage mode: reply-tagged single message floats above newer untagged")
    func triageReplyAboveNewerUntagged() {
        // Old reply-tagged message + newer untagged message.
        // Normal mode: untagged comes first (newer date).
        // Triage mode: reply tag (sortOrder=0) should come first regardless of date.
        let oldReply = makeSnapshot(
            messageId: "m_reply",
            date: baseDate,
            computedThreadId: "t_reply",
            actionTag: .reply
        )
        let newerUntagged = makeSnapshot(
            messageId: "m_plain",
            date: baseDate.addingTimeInterval(3600 * 24 * 3),  // 3 days later
            computedThreadId: "t_plain"
        )

        let normal = ThreadGroupBuilder.buildDisplayGroups(from: [oldReply, newerUntagged], mode: .normal)
        #expect(normal.count == 2)
        #expect(normal[0].representative.id == newerUntagged.id, "normal mode: newer comes first")
        #expect(normal[1].representative.id == oldReply.id)

        let triage = ThreadGroupBuilder.buildDisplayGroups(from: [oldReply, newerUntagged], mode: .triage)
        #expect(triage.count == 2)
        #expect(triage[0].representative.id == oldReply.id, "triage mode: reply tag floats to top even with older date")
        #expect(triage[0].threadTag == .reply)
        #expect(triage[1].representative.id == newerUntagged.id)
    }

    @Test("Triage mode: tag priority reply < none < archive < delete < untagged")
    func triageTagPriorityOrdering() {
        // All same date so only tag priority matters.
        let untagged = makeSnapshot(messageId: "m_u", date: baseDate, computedThreadId: "t_u")
        let archive = makeSnapshot(messageId: "m_a", date: baseDate, computedThreadId: "t_a", actionTag: .archive)
        let delete = makeSnapshot(messageId: "m_d", date: baseDate, computedThreadId: "t_d", actionTag: .delete)
        // NOTE: must be `ActionTag.none` not `.none` — when the parameter type is
        // `ActionTag?`, Swift resolves bare `.none` to `Optional.none` (i.e. nil).
        let none = makeSnapshot(messageId: "m_n", date: baseDate, computedThreadId: "t_n", actionTag: ActionTag.none)
        let reply = makeSnapshot(messageId: "m_r", date: baseDate, computedThreadId: "t_r", actionTag: .reply)

        // Pass in deliberately scrambled order
        let result = ThreadGroupBuilder.buildDisplayGroups(
            from: [untagged, delete, archive, none, reply],
            mode: .triage
        )
        #expect(result.count == 5)
        // Use fully-qualified `ActionTag.X` — bare `.none` on the RHS of an
        // `ActionTag?` comparison resolves to `Optional.none` (nil), not the
        // enum case.
        #expect(result[0].threadTag == ActionTag.reply,   "reply (sortOrder=0) first")
        #expect(result[1].threadTag == ActionTag.none,    "none (sortOrder=1) second")
        #expect(result[2].threadTag == ActionTag.archive, "archive (sortOrder=2) third")
        #expect(result[3].threadTag == ActionTag.delete,  "delete (sortOrder=3) fourth")
        #expect(result[4].threadTag == nil,               "untagged (sortOrder=99) last")
    }

    @Test("Triage mode: within same tag, date descending")
    func triageWithinTagDateDescending() {
        let olderReply = makeSnapshot(messageId: "m_old", date: baseDate, computedThreadId: "t_old", actionTag: .reply)
        let newerReply = makeSnapshot(messageId: "m_new", date: baseDate.addingTimeInterval(3600), computedThreadId: "t_new", actionTag: .reply)
        let result = ThreadGroupBuilder.buildDisplayGroups(from: [olderReply, newerReply], mode: .triage)
        #expect(result.count == 2)
        #expect(result[0].representative.id == newerReply.id, "within reply tag, newer first")
        #expect(result[1].representative.id == olderReply.id)
    }

    @Test("Triage mode: thread inherits highest-priority member's tag for sort")
    func triageThreadInheritsTopTag() {
        // Single-message untagged thread, newer date.
        let untaggedNewer = makeSnapshot(
            messageId: "u_new",
            date: baseDate.addingTimeInterval(3600 * 24 * 5),  // 5 days later
            computedThreadId: "t_plain"
        )
        // A thread with two messages: one untagged, one reply-tagged. Older date overall.
        let threadPlain = makeSnapshot(
            messageId: "th_a",
            date: baseDate,
            computedThreadId: "t_thread",
            actionTag: nil
        )
        let threadReply = makeSnapshot(
            messageId: "th_b",
            date: baseDate.addingTimeInterval(60),
            computedThreadId: "t_thread",
            actionTag: .reply
        )

        let result = ThreadGroupBuilder.buildDisplayGroups(
            from: [untaggedNewer, threadPlain, threadReply],
            mode: .triage
        )
        #expect(result.count == 2)
        // The thread should win — its threadTag is .reply (lowest sortOrder among members),
        // which beats the newer-dated untagged group in triage.
        #expect(result[0].id == "t_thread")
        #expect(result[0].threadTag == .reply)
        #expect(result[1].id == "t_plain")
    }
}
