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
///  2. One email in two folders shows once: the opened copy, else one with a text message. Headers
///     without a Message-ID are copies only when a provider id names the message in one account.
///  3. An email is the user's own when it is from one of their addresses or sits in a Sent folder.
///  4. The next reply goes to the newest email's Reply All people, never the user; more than one
///     other person makes a group.
///  5. A time stamp goes above the first bubble and after every gap of at least the threshold.
///  6. The Unread line goes above the first email that was unread at open, once.
///  7. An email that left out someone already in the chat (on an earlier email) carries who it went
///     to ("replied only to"), the user as "you" whichever address they used; an email to everyone,
///     or to everyone and someone new, carries nothing, and nobody who joined later counts (R3).
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

    @Test("Without a Message-ID, the same UID in two folders or two accounts is two emails; a provider id names one email in its account")
    func noMessageIdIsNotACopy() {
        func bare(_ uid: String, minutesAgo: Double, folder: String = "INBOX", account: String = "acc1") -> MessageHeader {
            MessageHeader(
                messageId: uid, subject: "Plans", from: "Alex Doe", fromAddress: "alex@example.com",
                to: Self.me, date: Self.now.addingTimeInterval(-minutesAgo * 60), snippet: "snippet \(uid)",
                folderId: "\(account):\(folder)", accountId: account, folderPath: folder,
                isInInbox: folder == "INBOX")
        }
        let parent = bare("1", minutesAgo: 60, folder: "Archive")
        let opened = bare("1", minutesAgo: 30)
        let newest = bare("1", minutesAgo: 5, account: "acc2")
        let chat = Self.thread([parent, opened, newest], preferred: opened.id)
        #expect(chat.items.map(\.id) == [parent.id, opened.id, newest.id], "three emails show, though their UIDs coincide")
        #expect(chat.newest?.id == newest.id, "the newest email is the newest, not the opened one")
        #expect(Set([parent, opened, newest].map(ChatThread.copyKey)).count == 3)
        // An empty Message-ID is no Message-ID.
        var emptyA = bare("2", minutesAgo: 20), emptyB = bare("2", minutesAgo: 20, folder: "Archive")
        emptyA.rfc822MessageId = ""
        emptyB.rfc822MessageId = ""
        #expect(Self.thread([emptyA, emptyB]).items.count == 2)

        // A provider id names the message itself: two folders of one account hold one email,
        // the same id in another account is another email.
        let gmailInbox = bare("18c2f0a1b2", minutesAgo: 10)
        let gmailLabel = bare("18c2f0a1b2", minutesAgo: 10, folder: "Work")
        let otherAccount = bare("18c2f0a1b2", minutesAgo: 10, account: "acc2")
        #expect(Self.thread([gmailInbox, gmailLabel], preferred: gmailLabel.id).items.map(\.id) == [gmailLabel.id])
        #expect(Self.thread([gmailInbox, otherAccount]).items.count == 2)
        // A Message-ID still makes copies, whatever the UIDs.
        let rfcA = Self.header("7", minutesAgo: 3, rfc822: "<one@example.com>")
        let rfcB = Self.header("8", minutesAgo: 3, folder: "Archive", rfc822: "<one@example.com>")
        #expect(ChatThread.copyKey(rfcA) == ChatThread.copyKey(rfcB))
        #expect(Self.thread([rfcA, rfcB]).items.count == 1)
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

    @Test("A newer email with the same UID and no Message-ID changes the newest email's key, so the reply choice resets")
    func newestKeyChangesWithCoincidingUIDs() {
        func bare(_ uid: String, minutesAgo: Double, account: String) -> MessageHeader {
            MessageHeader(
                messageId: uid, subject: "Plans", from: "Alex Doe", fromAddress: "alex@example.com",
                to: Self.me, date: Self.now.addingTimeInterval(-minutesAgo * 60), snippet: "snippet",
                folderId: "\(account):INBOX", accountId: account, folderPath: "INBOX", isInInbox: true)
        }
        let first = bare("1", minutesAgo: 30, account: "acc1")
        let newer = bare("1", minutesAgo: 5, account: "acc2")
        let before = Self.thread([first]).newest.map(ChatThread.copyKey)
        let after = Self.thread([first, newer]).newest.map(ChatThread.copyKey)
        #expect(before != nil && after != nil)
        #expect(before != after, "the reply choice resets when a new email becomes the newest")
        #expect(first.stableId == newer.stableId, "the bare-UID stableId would not have changed")
    }

    @Test("The chat view finds an email by its copy key, never by the bare-UID stableId")
    func chatViewUsesCopyKey() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("TabMail/Views/Chat/ChatThreadView.swift"), encoding: .utf8)
        #expect(!text.contains("stableId"), "two emails with one UID and no Message-ID would be taken for one")
        #expect(text.contains("ChatThread.copyKey($0.header) == ChatThread.copyKey(opened)"), "the opened email is found by its copy key")
    }

    // MARK: - 7. Replied only to

    private static let sarah = "Sarah Chen <sarah@example.com>"
    private static let david = "David Kim <david@example.com>"
    private static let priya = "Priya Vasanth <priya@example.com>"
    private static let sam = "Sam Lee <sam@example.com>"

    @Test("An email that left someone out carries who it went to; one to everyone carries nothing")
    func repliedOnlyTo() throws {
        let all = Self.header("1", from: "Sarah Chen", fromAddress: "sarah@example.com",
                              to: "me@example.com, \(Self.david)", cc: "\(Self.priya), \(Self.sam)", minutesAgo: 50)
        let toMe = Self.header("2", from: "Priya Vasanth", fromAddress: "priya@example.com",
                               to: "me@example.com", minutesAgo: 40)
        let mine = Self.header("3", from: "Me", fromAddress: Self.me, to: Self.priya, minutesAgo: 30)
        let three = Self.header("4", from: "Sam Lee", fromAddress: "sam@example.com",
                                to: "me@example.com, \(Self.david)", cc: Self.priya, minutesAgo: 20)
        let allAgain = Self.header("5", from: "Sarah Chen", fromAddress: "sarah@example.com",
                                   to: "me@example.com, \(Self.david), \(Self.priya)", cc: Self.sam, minutesAgo: 10)

        let chat = Self.thread([all, toMe, mine, three, allAgain])
        guard chat.items.count == 5 else { Issue.record("five bubbles"); return }

        #expect(chat.items[0].repliedOnlyTo == nil, "to everyone")
        #expect(chat.items[4].repliedOnlyTo == nil, "to everyone, To and Cc in another order")

        let onlyMe = try #require(chat.items[1].repliedOnlyTo)
        #expect(onlyMe.includesYou && onlyMe.people.isEmpty)
        #expect(onlyMe.label() == "you")

        let ownOnly = try #require(chat.items[2].repliedOnlyTo)
        #expect(!ownOnly.includesYou, "the user sent it")
        #expect(ownOnly.people.map(\.name) == ["Priya Vasanth"])

        let some = try #require(chat.items[3].repliedOnlyTo)
        #expect(some.names == ["you", "David Kim", "Priya Vasanth"])
        #expect(some.label() == "you, David Kim +1", "one line: two names, then +N")
        #expect(some.label(nameCount: 3) == "you, David Kim, Priya Vasanth")
    }

    @Test("Someone new on an email joins the chat; it is not \"only\"")
    func someoneNewIsNotOnly() {
        let first = Self.header("1", from: "Sarah Chen", fromAddress: "sarah@example.com",
                                to: "me@example.com", cc: Self.david, minutesAgo: 20)
        let adds = Self.header("2", from: "David Kim", fromAddress: "david@example.com",
                               to: "me@example.com, \(Self.sarah)", cc: Self.priya, minutesAgo: 10)
        let chat = Self.thread([first, adds])
        #expect(chat.items.map(\.repliedOnlyTo) == [nil, nil] as [ChatThread.OnlyTo?],
                "the first email had everyone then in the chat; the second added Priya")
        // Priya is in the chat now, so an email without her is "only".
        let later = Self.header("3", from: "Sarah Chen", fromAddress: "sarah@example.com",
                                to: "me@example.com, \(Self.david)", minutesAgo: 5)
        let longer = Self.thread([first, adds, later])
        #expect(longer.items[2].repliedOnlyTo?.people.map(\.name) == ["David Kim"])
    }

    @Test("The user is one person, whichever of their addresses an email used")
    func userIsOnePerson() {
        let toWork = Self.header("1", from: "Sarah Chen", fromAddress: "sarah@example.com",
                                 to: "work@example.com", minutesAgo: 20)
        let toHome = Self.header("2", from: "Sarah Chen", fromAddress: "sarah@example.com",
                                 to: "Me <me@example.com>", minutesAgo: 10)
        let chat = ChatThread(
            members: [toWork, toHome], replyAddresses: { [$0.fromAddress] },
            ownAddresses: [Self.me, "work@example.com"], draftFolderIds: [], sentFolderIds: [],
            unreadAtOpen: [], preferredId: nil)
        #expect(chat.items.map(\.repliedOnlyTo) == [nil, nil] as [ChatThread.OnlyTo?])
    }
}
