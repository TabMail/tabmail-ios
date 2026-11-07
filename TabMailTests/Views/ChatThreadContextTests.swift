/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Synchronization
import Testing
@testable import TabMail

/// ADR-IOS-103: what the chat screen reads besides its headers, and when it opens at all.
///
/// THE SYSTEM PROPERTIES pinned here:
///  1. The context names the thread's Drafts and Sent folders, the union of its labels, and per
///     email its top-level attachment names and an invite the user can add.
///  2. An invite card stands for its calendar file: the file is not also a chip. Replies, cancels
///     and files without a start time are no card.
///  3. A thread opens as a chat only with the chat view on, outside the demo's AI-off mode and the
///     tutorial.
///  4. The inbox row shows the text message only with the chat view on; else the snippet.
///  5. An email the body writer confirms empty is done: its bubble says so, never "Summarizing".
@Suite("Chat thread context", .serialized)
struct ChatThreadContextTests {

    private static func ics(method: String = "REQUEST", start: Bool = true) -> String {
        let startLine = start ? "DTSTART:20990105T170000Z\nDTEND:20990105T180000Z\n" : ""
        return """
        BEGIN:VCALENDAR
        VERSION:2.0
        METHOD:\(method)
        BEGIN:VEVENT
        SUMMARY:Planning
        \(startLine)ORGANIZER;CN=Alex Doe:mailto:alex@example.com
        ATTENDEE;CN=Bo Lee:mailto:bo@example.com
        END:VEVENT
        END:VCALENDAR
        """
    }

    private static func header(_ uid: String, folder: String = "INBOX") -> MessageHeader {
        MessageHeader(
            messageId: uid, subject: "Plans", from: "Alex", fromAddress: "alex@example.com",
            to: "acc1@example.com", date: Date(), snippet: "snippet", folderId: "acc1:\(folder)",
            accountId: "acc1", folderPath: folder, isInInbox: folder == "INBOX")
    }

    private static func attachmentsJSON(_ list: [AttachmentInfo]) throws -> String {
        String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
    }

    // MARK: - 1 and 2. Loading

    @Test("The context reads folders, labels, attachments and the invite for the thread")
    func loadsContext() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        _ = try FolderEpochTestFixture.makeAccount(id: "acc1", provider: .imap, pool: pool)
        for (path, role) in [("INBOX", FolderRole.inbox), ("Drafts", .drafts), ("Sent", .sent), ("Archive", .archive)] {
            try FolderEpochTestFixture.insertFolder(accountId: "acc1", path: path, role: role, pool: pool)
        }
        let invite = Self.header("1")
        let files = Self.header("2", folder: "Archive")
        let plain = Self.header("3")
        try await pool.write { db in
            for header in [invite, files, plain] { try header.insert(db) }

            var inviteBody = MessageBody(contentKey: ContentKey(rawValue: invite.id), htmlContent: "<p>x</p>")
            inviteBody.icsText = Self.ics()
            inviteBody.attachmentsJSON = try Self.attachmentsJSON([
                AttachmentInfo(filename: "invite.ics", contentType: "text/calendar; method=REQUEST", section: "2", size: 10, encoding: nil),
                AttachmentInfo(filename: "agenda.pdf", contentType: "application/pdf", section: "3", size: 10, encoding: nil),
            ])
            try inviteBody.insert(db)

            var filesBody = MessageBody(contentKey: ContentKey(rawValue: files.id), htmlContent: "<p>y</p>")
            // A cancel is no card, so its calendar file stays a chip; a file inside an attached
            // email is not this email's.
            filesBody.icsText = Self.ics(method: "CANCEL")
            filesBody.attachmentsJSON = try Self.attachmentsJSON([
                AttachmentInfo(filename: "cancel.ics", contentType: "text/calendar", section: "2", size: 10, encoding: nil),
                AttachmentInfo(filename: "inner.png", contentType: "image/png", section: "3.2", size: 10, encoding: nil, parentEmlSection: "3"),
            ])
            try filesBody.insert(db)

            try UserLabel(accountId: "acc1", providerLabelId: "z", name: "Zed", isSystem: false).insert(db)
            try UserLabel(accountId: "acc1", providerLabelId: "a", name: "alpha", isSystem: false).insert(db)
            try MessageUserLabel(messageId: invite.id, userLabelId: "acc1:z").insert(db)
            try MessageUserLabel(messageId: files.id, userLabelId: "acc1:z").insert(db)
            try MessageUserLabel(messageId: files.id, userLabelId: "acc1:a").insert(db)
        }

        let context = await ChatThreadContext.load(members: [invite, files, plain], pool: PrioritizedDatabase(pool: pool))

        #expect(context.isLoaded)
        #expect(context.draftFolderIds == ["acc1:Drafts"])
        #expect(context.sentFolderIds == ["acc1:Sent"])
        #expect(context.ownAddresses == ["acc1@example.com"])
        #expect(context.labels.map(\.name) == ["alpha", "Zed"], "the union, one each, by name")

        #expect(context.extras[invite.id]?.attachmentNames == ["agenda.pdf"], "the card stands for the calendar file")
        #expect(context.extras[invite.id]?.invite?.parsed.title == "Planning")
        #expect(context.extras[files.id]?.attachmentNames == ["cancel.ics"])
        #expect(context.extras[files.id]?.invite == nil)
        #expect(context.extras[plain.id] == nil, "no body yet, nothing extra")
    }

    @Test("The context reads every email's attachments and invite, never its stored HTML")
    func loadNeverReadsTheHTML() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let statements = Mutex<[String]>([])
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { event in statements.withLock { $0.append("\(event)") } }
        }
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path, configuration: config)
        _ = try AppDatabase(dbPool: pool)
        _ = try FolderEpochTestFixture.makeAccount(id: "acc1", provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "acc1", path: "INBOX", role: .inbox, pool: pool)
        // A long thread: the uncapped lookup hands every member to the load.
        let members = (1...30).map { Self.header(String($0)) }
        try await pool.write { db in
            for header in members {
                try header.insert(db)
                var body = MessageBody(contentKey: ContentKey(rawValue: header.id),
                                       htmlContent: String(repeating: "<p>long body</p>", count: 500))
                body.attachmentsJSON = try Self.attachmentsJSON([
                    AttachmentInfo(filename: "notes-\(header.messageId).pdf", contentType: "application/pdf", section: "2", size: 10, encoding: nil),
                ])
                if header.messageId == "1" { body.icsText = Self.ics() }
                try body.insert(db)
            }
        }
        statements.withLock { $0.removeAll() }

        let context = await ChatThreadContext.load(members: members, pool: PrioritizedDatabase(pool: pool))

        #expect(context.extras.count == members.count, "every member, not a window")
        #expect(context.extras[members[29].id]?.attachmentNames == ["notes-30.pdf"])
        #expect(context.extras[members[0].id]?.invite?.parsed.title == "Planning")
        let bodyReads = statements.withLock { $0 }.filter { $0.contains("\"messageBody\"") }
        #expect(!bodyReads.isEmpty, "the load reads the body table")
        #expect(bodyReads.allSatisfy { !$0.contains("htmlContent") && !$0.contains("*") },
                "only the attachment list and calendar file: \(bodyReads)")
    }

    @Test("A read failure still finishes loading, with nothing extra")
    func loadFailureFinishes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // No migrations: every table is missing.
        let pool = try DatabasePool(path: dir.appendingPathComponent("empty.sqlite").path)

        let context = await ChatThreadContext.load(members: [Self.header("1")], pool: PrioritizedDatabase(pool: pool))

        #expect(context.isLoaded)
        #expect(context.extras.isEmpty)
        #expect(context.accounts.isEmpty)
    }

    @Test("An email the body writer confirms empty is done, and its bubble says it has no content, not Summarizing")
    func confirmedEmptyEmailIsDone() async throws {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        _ = try FolderEpochTestFixture.makeAccount(id: "acc1", provider: .imap, pool: pool)
        try FolderEpochTestFixture.insertFolder(accountId: "acc1", path: "INBOX", role: .inbox, pool: pool)
        var original = Self.header("empty")
        original.rfc822MessageId = "<empty@example.com>"
        original.headerComplete = true
        // One more empty fetch confirms the body empty.
        original.emptyFetchCount = 2
        let stored = original
        try await pool.write { try stored.insert($0) }
        let item = { (header: MessageHeader) in
            ChatThread(members: [header], replyAddresses: { [$0.fromAddress] }, ownAddresses: [],
                       draftFolderIds: [], sentFolderIds: [], unreadAtOpen: [], preferredId: nil).items[0]
        }
        #expect(item(original).textMessage == nil, "before the body: still summarizing")

        let (result, _) = await BodyFetchProcessor.process(fetchResult: .init(
            item: .init(headerId: original.id, accountId: original.accountId, folderPath: original.folderPath,
                        messageId: original.messageId, isInInbox: true),
            renderedBody: MessageBody.create(contentKey: ContentKey(rawValue: original.id), htmlBody: nil),
            plainText: nil, hasAttachments: false, hasUnresolvedICS: false,
            fetchedRfc822MessageId: original.rfc822MessageId), enableAI: false)
        guard case .confirmedEmpty = result else {
            Issue.record("the real empty-body writer did not confirm the body empty: \(result)")
            return
        }
        let finished = try #require(try await pool.read { try MessageHeader.fetchOne($0, key: stored.id) })
        #expect(finished.summaryBlurb == MessageHeader.noContentSummary)
        #expect(ActiveAIQueue.summaryDone(finished, forChat: true), "the queue counts it done")
        #expect(item(finished).textMessage == MessageHeader.noContentSummary, "so the bubble never waits for a text message")
    }

    @Test("An invite card needs a request the user can add, with a start time")
    func inviteFromCalendarFile() {
        #expect(ChatInvite.from(icsText: Self.ics())?.parsed.title == "Planning")
        #expect(ChatInvite.from(icsText: Self.ics(method: "CANCEL")) == nil)
        #expect(ChatInvite.from(icsText: Self.ics(method: "REPLY")) == nil)
        #expect(ChatInvite.from(icsText: Self.ics(start: false)) == nil)
        #expect(ChatInvite.from(icsText: "not a calendar") == nil)
    }

    // MARK: - Time stamps

    @Test("Time stamps read Today, Yesterday, the weekday within the week, else the date")
    func timeStamps() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }

        let earlier = now.addingTimeInterval(-3600)
        #expect(ChatTimeStamp.text(for: earlier, now: now, calendar: calendar) == "Today \(time(earlier))")

        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        #expect(ChatTimeStamp.text(for: yesterday, now: now, calendar: calendar) == "Yesterday \(time(yesterday))")

        let weekday = DateFormatter()
        weekday.calendar = calendar
        weekday.timeZone = calendar.timeZone
        weekday.dateFormat = "EEE"
        let threeDays = calendar.date(byAdding: .day, value: -3, to: now)!
        #expect(ChatTimeStamp.text(for: threeDays, now: now, calendar: calendar)
                == "\(weekday.string(from: threeDays)) \(time(threeDays))")

        let dated = DateFormatter()
        dated.calendar = calendar
        dated.timeZone = calendar.timeZone
        let longAgo = calendar.date(byAdding: .day, value: -400, to: now)!
        dated.dateFormat = "MMM d, yyyy"
        #expect(ChatTimeStamp.text(for: longAgo, now: now, calendar: calendar)
                == "\(dated.string(from: longAgo)), \(time(longAgo))")

        // Older than the week but this year: no year. Only checkable once the year has 8 days behind.
        let eightDays = calendar.date(byAdding: .day, value: -8, to: now)!
        if calendar.isDate(eightDays, equalTo: now, toGranularity: .year) {
            dated.dateFormat = "MMM d"
            #expect(ChatTimeStamp.text(for: eightDays, now: now, calendar: calendar)
                    == "\(dated.string(from: eightDays)), \(time(eightDays))")
        }

        // A future date (a clock skew) is not "this week".
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        #expect(!ChatTimeStamp.text(for: tomorrow, now: now, calendar: calendar).hasPrefix(weekday.string(from: tomorrow)))
    }

    // MARK: - Event card format

    @Test("Event times: the day for an all-day event, else the start and end time")
    func eventFormat() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let start = Date()
        let end = start.addingTimeInterval(3600)
        #expect(CalendarEventFormat.time(start: start, end: end, isAllDay: true, timeZone: utc).hasSuffix("(all day)"))
        let timed = CalendarEventFormat.time(start: start, end: end, isAllDay: false, timeZone: utc)
        #expect(timed.contains(" – "))
        #expect(!timed.contains("(all day)"))

        #expect(CalendarEventFormat.timeZone(id: "America/Vancouver").identifier == "America/Vancouver")
        #expect(CalendarEventFormat.timeZone(id: "Not/AZone") == .current)
        #expect(CalendarEventFormat.timeZone(id: nil) == .current)
        let vancouver = try #require(TimeZone(identifier: "America/Vancouver"))
        #expect(CalendarEventFormat.timeZoneLabel(vancouver).hasSuffix("(America/Vancouver)"))
        // A zone whose abbreviation is its identifier is named once, not "GMT (GMT)".
        let utcLabel = CalendarEventFormat.timeZoneLabel(utc)
        #expect(utcLabel.contains(utc.identifier))
        #expect(utcLabel != "\(utc.identifier) (\(utc.identifier))")
    }

    // MARK: - 3 and 4. Opening and the inbox row

    @Test("A thread opens as a chat only with the chat view on, outside the demo's AI-off mode and the tutorial")
    func opensInChat() {
        for active in [false, true] {
            for demo in [false, true] {
                for tutorial in [false, true] {
                    #expect(ChatViewConfig.opensInChat(active: active, demoHidesAI: demo, tutorialRunning: tutorial)
                            == (active && !demo && !tutorial))
                }
            }
        }
    }

    @Test("The inbox row shows the text message with the chat view on, else the snippet")
    func rowPreview() {
        var header = Self.header("1")
        header.summaryTextMessage = "See you at noon"
        #expect(MessageSnapshot(from: header).preview(chatViewActive: true) == "See you at noon")
        #expect(MessageSnapshot(from: header).preview(chatViewActive: false) == "snippet")

        header.summaryTextMessage = ""
        #expect(MessageSnapshot(from: header).preview(chatViewActive: true) == "snippet")
        header.summaryTextMessage = nil
        #expect(MessageSnapshot(from: header).preview(chatViewActive: true) == "snippet")
    }
}
