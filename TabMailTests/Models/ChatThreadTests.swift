/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// ADR-IOS-103: the chat view shows a thread as bubbles.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. Every email of the thread shows once, oldest first; drafts never show (Q22).
///  2. One email in two folders shows once: the opened copy, else one with a text message.
///  3. An email is the user's own when it is from one of their addresses or sits in a Sent folder.
///  4. The next reply goes to the newest email's Reply All people, never the user; more than one
///     other person makes a group.
///  5. A time stamp goes above the first bubble and after every gap of at least the threshold.
///  6. The Unread line goes above the first email that was unread at open, once.
@Suite("Chat thread")
struct ChatThreadTests {
    private static let me = "me@example.com"
    private static let now = Date()

    private static func header(
        _ uid: String,
        from: String = "Alex Doe",
        fromAddress: String = "alex@example.com",
        to: String = "me@example.com",
        cc: String = "",
        minutesAgo: Double,
        folder: String = "INBOX",
        rfc822: String? = nil,
        text: String? = nil
    ) -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "Plans", from: from, fromAddress: fromAddress, to: to,
            date: now.addingTimeInterval(-minutesAgo * 60), snippet: "snippet \(uid)",
            folderId: "acc1:\(folder)", accountId: "acc1", folderPath: folder, isInInbox: folder == "INBOX")
        header.cc = cc
        header.rfc822MessageId = rfc822 ?? "<\(uid)@example.com>"
        header.summaryTextMessage = text
        return header
    }

    private static func thread(
        _ members: [MessageHeader],
        reply: [String]? = nil,
        unread: Set<String> = [],
        preferred: String? = nil,
        gap: TimeInterval = 15 * 60
    ) -> ChatThread {
        ChatThread(
            members: members,
            replyAddresses: { header in reply ?? [header.fromAddress] },
            ownAddresses: [me],
            draftFolderIds: ["acc1:Drafts"],
            sentFolderIds: ["acc1:Sent"],
            unreadAtOpen: unread,
            preferredId: preferred,
            timeStampGap: gap)
    }

    // MARK: - 1. Order and drafts

    @Test("Bubbles run oldest first, ties by id, and drafts never show")
    func orderAndDrafts() {
        let a = Self.header("1", minutesAgo: 60)
        let b = Self.header("2", minutesAgo: 30)
        let tieLow = Self.header("3", minutesAgo: 10)
        let tieHigh = Self.header("4", minutesAgo: 10)
        let draft = Self.header("5", minutesAgo: 1, folder: "Drafts")

        let chat = Self.thread([tieHigh, draft, b, tieLow, a])

        #expect(chat.items.map(\.id) == [a.id, b.id, tieLow.id, tieHigh.id])
        #expect(chat.newest?.id == tieHigh.id, "the newest email is never a draft")
    }

    // MARK: - 2. One copy each

    @Test("An email in two folders shows once: the opened copy wins")
    func oneCopyPrefersOpened() {
        let inbox = Self.header("10", minutesAgo: 5, rfc822: "<same@example.com>", text: "Hi")
        let archive = Self.header("20", minutesAgo: 5, folder: "Archive", rfc822: "<same@example.com>")

        #expect(Self.thread([inbox, archive], preferred: archive.id).items.map(\.id) == [archive.id])
        #expect(Self.thread([archive, inbox], preferred: archive.id).items.map(\.id) == [archive.id])
    }

    @Test("Without the opened copy, the copy with a text message wins, else the first")
    func oneCopyPrefersText() {
        let bare = Self.header("10", minutesAgo: 5, rfc822: "<same@example.com>")
        let summarized = Self.header("20", minutesAgo: 5, folder: "Archive", rfc822: "<same@example.com>", text: "Hi")
        let other = Self.header("30", minutesAgo: 5, folder: "Old", rfc822: "<same@example.com>")

        #expect(Self.thread([bare, summarized]).items.map(\.id) == [summarized.id])
        #expect(Self.thread([summarized, bare]).items.map(\.id) == [summarized.id])
        #expect(Self.thread([bare, other]).items.map(\.id) == [bare.id])
    }

    // MARK: - 3. Own emails

    @Test("An email is the user's own when from their address, any case, or in Sent")
    func ownEmails() {
        let mine = Self.header("1", from: "Me", fromAddress: "ME@Example.com", minutesAgo: 30)
        let sentCopy = Self.header("2", from: "Alias", fromAddress: "alias@example.com", minutesAgo: 20, folder: "Sent")
        let theirs = Self.header("3", minutesAgo: 10)

        let chat = Self.thread([mine, sentCopy, theirs])

        #expect(chat.items.map(\.isOwn) == [true, true, false])
    }

    // MARK: - 4. Reply people and groups

    @Test("The next reply goes to the newest email's Reply All people, named, never the user")
    func replyPeople() {
        let older = Self.header("1", from: "Bo Lee", fromAddress: "bo@example.com", minutesAgo: 60)
        let newest = Self.header(
            "2", from: "Alex Doe", fromAddress: "alex@example.com",
            to: "Me <me@example.com>, \"Lee, Bo\" <bo@example.com>", minutesAgo: 5)

        let chat = Self.thread(
            [older, newest],
            reply: ["Alex@Example.com", "me@example.com", "bo@example.com", "alex@example.com", "nobody@example.com"])

        #expect(chat.replyPeople.map(\.address) == ["alex@example.com", "bo@example.com", "nobody@example.com"])
        // A From name beats a recipient name; an address with no name shows its part before the @.
        #expect(chat.replyPeople.map(\.name) == ["Alex Doe", "Bo Lee", "nobody"])
        #expect(chat.isGroup)
    }

    @Test("One other person is a one-to-one chat; a second sender makes it a group")
    func groupNeedsTwoOthers() {
        let theirs = Self.header("1", minutesAgo: 30)
        let mine = Self.header("2", from: "Me", fromAddress: Self.me, minutesAgo: 20)
        #expect(!Self.thread([theirs, mine], reply: ["alex@example.com"]).isGroup)

        let third = Self.header("3", from: "Bo", fromAddress: "bo@example.com", minutesAgo: 10)
        #expect(Self.thread([theirs, mine, third], reply: ["bo@example.com"]).isGroup,
                "someone who wrote in the thread counts even when the reply skips them")
    }

    @Test("An empty thread has no bubbles, no reply people and no newest email")
    func emptyThread() {
        let chat = Self.thread([Self.header("1", minutesAgo: 1, folder: "Drafts")])
        #expect(chat.items.isEmpty)
        #expect(chat.replyPeople.isEmpty)
        #expect(chat.newest == nil)
        #expect(!chat.isGroup)
    }

    // MARK: - 5. Time stamps

    @Test("A time stamp goes above the first bubble and after a gap of at least the threshold")
    func timeStamps() {
        let first = Self.header("1", minutesAgo: 120)
        let close = Self.header("2", minutesAgo: 110)
        let atGap = Self.header("3", minutesAgo: 95)
        let after = Self.header("4", minutesAgo: 10)

        let chat = Self.thread([first, close, atGap, after], gap: 15 * 60)

        #expect(chat.items.map(\.showsTimeStamp) == [true, false, true, true])
    }

    // MARK: - 6. Unread line

    @Test("The Unread line goes above the first email unread at open, and only there")
    func unreadLine() {
        let read = Self.header("1", minutesAgo: 30)
        let unreadA = Self.header("2", minutesAgo: 20)
        let unreadB = Self.header("3", minutesAgo: 10)

        let chat = Self.thread([read, unreadA, unreadB], unread: [unreadA.id, unreadB.id])
        #expect(chat.items.map(\.showsUnreadLine) == [false, true, false])

        #expect(Self.thread([read, unreadA]).items.allSatisfy { !$0.showsUnreadLine })
    }

    // MARK: - Bubble text, avatars, header

    @Test("A bubble's text message is the summary's, an empty one counts as still summarizing, and an email with nothing to summarize says so")
    func textMessage() {
        var summarizedNoText = Self.header("4", minutesAgo: 0.5)
        summarizedNoText.summaryBlurb = "A summary without its text message yet."
        var noContent = Self.header("5", minutesAgo: 0.2)
        noContent.summaryBlurb = MessageHeader.noContentSummary
        let chat = Self.thread([
            Self.header("1", minutesAgo: 3, text: "See you then"),
            Self.header("2", minutesAgo: 2, text: ""),
            Self.header("3", minutesAgo: 1),
            summarizedNoText,
            noContent,
        ])
        #expect(chat.items.map(\.textMessage) == ["See you then", nil, nil, nil, MessageHeader.noContentSummary])
    }

    @Test("Initials come from the first two words of the name, else the address")
    func initials() {
        #expect(ChatThread.Person(address: "a@example.com", name: "alex doe smith").initials == "AD")
        #expect(ChatThread.Person(address: "a@example.com", name: "Doe, Alex").initials == "DA")
        #expect(ChatThread.Person(address: "a@example.com", name: "Alex").initials == "A")
        #expect(ChatThread.Person(address: "zed@example.com", name: "").initials == "Z")
    }

    @Test("A person's color is stable, in range, and differs between people")
    func colorIndex() {
        let alex = ChatThread.Person(address: "alex@example.com", name: "Alex")
        let alexRenamed = ChatThread.Person(address: "alex@example.com", name: "A. Doe")
        let count = 8
        let picks = (0..<40).map { ChatThread.Person(address: "p\($0)@example.com", name: "").colorIndex(count: count) }

        #expect(alex.colorIndex(count: count) == alexRenamed.colorIndex(count: count), "by address, not name")
        #expect(picks.allSatisfy { (0..<count).contains($0) })
        #expect(Set(picks).count > 1)
        #expect(alex.colorIndex(count: 0) == 0)
    }

    @Test("The header shows up to two names, then +N")
    func headerTitle() {
        let people = ["Ann", "Bo", "Cy", "Di"].map { ChatThread.Person(address: "\($0)@example.com", name: $0) }
        #expect(ChatThread.headerTitle(Array(people.prefix(1))) == "Ann")
        #expect(ChatThread.headerTitle(Array(people.prefix(2))) == "Ann, Bo")
        #expect(ChatThread.headerTitle(people) == "Ann, Bo +2")
        #expect(ChatThread.headerTitle(people, nameCount: 3) == "Ann, Bo, Cy +1")
        #expect(ChatThread.headerTitle([]) == "")
    }
}
