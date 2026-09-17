/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

/// Gmail arrival-date correctness. Gmail's `internalDate` is the authored
/// `Date:` for Google-generated and Google-relayed mail, so a mailing-list
/// message accepted today can carry an `internalDate` weeks old and sort
/// below a month of newer mail. The display/sort `date` therefore comes from
/// the top `Received:` header, while `providerDate` keeps `internalDate` for
/// everything Gmail itself orders by. These suites pin both halves and the
/// stale-window invariant that makes the split necessary.
private func wholeSeconds(_ date: Date) -> Date {
    Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
}

private func rfc2822(_ date: Date) -> String {
    EmailDateParsing.rfc2822.string(from: date)
}

private func gmailJSON(internalDate: Date, headers: [[String: String]]) -> [String: Any] {
    [
        "id": "m1",
        "threadId": "t1",
        "internalDate": String(Int(internalDate.timeIntervalSince1970 * 1000)),
        "labelIds": ["INBOX"],
        "payload": ["headers": headers],
    ]
}

@Suite("EmailDateParsing.receivedHeaderDate")
struct ReceivedHeaderDateTests {
    @Test("timestamp after the last semicolon parses, with and without the weekday")
    func parsesTail() {
        let stamp = wholeSeconds(Date())
        let withWeekday = "from mx.example.com (mx.example.com. [192.0.2.1]) by mail.example.net with ESMTPS id abc; \(rfc2822(stamp))"
        #expect(EmailDateParsing.receivedHeaderDate(withWeekday) == stamp)

        let noWeekdayFormatter = DateFormatter()
        noWeekdayFormatter.locale = Locale(identifier: "en_US_POSIX")
        noWeekdayFormatter.dateFormat = "d MMM yyyy HH:mm:ss Z"
        let withoutWeekday = "by relay.example.net; \(noWeekdayFormatter.string(from: stamp))"
        #expect(EmailDateParsing.receivedHeaderDate(withoutWeekday) == stamp)
    }

    @Test("CFWS comments and folded whitespace around the timestamp are ignored")
    func stripsCommentsAndFolding() {
        let stamp = wholeSeconds(Date())
        let raw = "from a (b; c) by d\r\n        for <user@example.com>;\r\n        \(rfc2822(stamp))\n (PDT)"
        #expect(EmailDateParsing.receivedHeaderDate(raw) == stamp)
    }

    @Test("comments after the date, nested comments and escaped parens are RFC 5322 CFWS, not the tail")
    func commentAwareDelimiter() {
        let stamp = wholeSeconds(Date())
        let rfc = rfc2822(stamp)
        // A `;` inside a comment AFTER the date must not become the delimiter.
        #expect(EmailDateParsing.receivedHeaderDate("from a by b; \(rfc) (UTC; delivery)") == stamp)
        // Nested comments and a quoted-pair `\)` inside one.
        #expect(EmailDateParsing.receivedHeaderDate("from a (outer (inner; x)) by b; \(rfc) (tz (nested))") == stamp)
        #expect(EmailDateParsing.receivedHeaderDate("from a (paren \\) here; not-date) by b; \(rfc)") == stamp)
        // A comment that itself contains `;` BEFORE the real delimiter (unchanged).
        #expect(EmailDateParsing.receivedHeaderDate("from a (b; c) by d; \(rfc)") == stamp)
        // A quoted-pair `\)` inside the TRAILING comment, after the date: the
        // tail scanner must not close the comment early and leak `comment; still
        // comment)` into the date-time.
        #expect(EmailDateParsing.receivedHeaderDate("from a by b; \(rfc) (zone \\) comment; still comment)") == stamp)
    }

    @Test("seconds are optional in RFC 5322 date-time")
    func optionalSeconds() {
        let minute = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE, d MMM yyyy HH:mm Z"
        #expect(EmailDateParsing.receivedHeaderDate("by relay; \(fmt.string(from: minute))") == minute)
        fmt.dateFormat = "d MMM yyyy HH:mm Z"
        #expect(EmailDateParsing.receivedHeaderDate("by relay; \(fmt.string(from: minute))") == minute)
    }

    @Test("RFC 5322 obs-year: two- and three-digit years normalize instead of parsing as year 26 AD")
    func obsoleteYearNormalizes() {
        let stamp = wholeSeconds(Date())
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "d MMM yy HH:mm:ss Z"          // e.g. "16 Sep 26 …" → this century
        #expect(EmailDateParsing.receivedHeaderDate("by relay; \(fmt.string(from: stamp))") == stamp)
        fmt.dateFormat = "EEE, d MMM yy HH:mm:ss Z"
        #expect(EmailDateParsing.receivedHeaderDate("by relay; \(fmt.string(from: stamp))") == stamp)
        // 50–99 → 1900s; three digits → 1900 + value (fixed points of the spec, not the clock).
        fmt.dateFormat = "d MMM yyyy HH:mm:ss Z"
        let y1999 = EmailDateParsing.receivedHeaderDate("by relay; 1 Jan 99 00:00:00 +0000")
        #expect(y1999 == RFC5322Parse.parseRFC5322Date("1 Jan 1999 00:00:00 +0000"))
        let y126 = EmailDateParsing.receivedHeaderDate("by relay; 1 Jan 126 00:00:00 +0000")
        #expect(y126 == RFC5322Parse.parseRFC5322Date("1 Jan 2026 00:00:00 +0000"))
        // Four-digit control is untouched.
        #expect(EmailDateParsing.receivedHeaderDate("by relay; \(fmt.string(from: stamp))") == stamp)
        for parsed in [y1999, y126] {
            let year = Calendar(identifier: .gregorian).component(.year, from: parsed ?? .distantPast)
            #expect(year >= 1900, "an obsolete year must never yield a first-millennium date")
        }
    }

    @Test("a header without a semicolon or with an unparseable tail is nil, never a guessed date")
    func rejectsMalformed() {
        #expect(EmailDateParsing.receivedHeaderDate("from a by b with SMTP id c") == nil)
        #expect(EmailDateParsing.receivedHeaderDate("from a by b; yesterday-ish") == nil)
        #expect(EmailDateParsing.receivedHeaderDate("from a by b;   ") == nil)
    }
}

@Suite("GmailParse — arrival date from the top Received header")
struct GmailParseReceivedDateTests {
    @Test("date is the FIRST Received hop's timestamp; providerDate stays internalDate")
    func topReceivedWins() {
        let arrival = wholeSeconds(Date().addingTimeInterval(-3_600))
        let earlierHop = arrival.addingTimeInterval(-90)
        let authored = arrival.addingTimeInterval(-55 * 86_400)
        let json = gmailJSON(internalDate: authored, headers: [
            ["name": "Subject", "value": "list post"],
            ["name": "Received", "value": "from lists.example.org by mx.example.com; \(rfc2822(arrival))"],
            ["name": "Received", "value": "from sender.example.net by lists.example.org; \(rfc2822(earlierHop))"],
            ["name": "Date", "value": rfc2822(authored)],
        ])
        let m = GmailParse.parseMessage(json)
        #expect(m?.date == arrival)
        #expect(m?.providerDate == authored)
    }

    @Test("a Received header with a trailing comment containing ';' still supplies date")
    func trailingCommentReceivedWins() {
        let arrival = wholeSeconds(Date().addingTimeInterval(-3_600))
        let authored = arrival.addingTimeInterval(-40 * 86_400)
        let m = GmailParse.parseMessage(gmailJSON(internalDate: authored, headers: [
            ["name": "Received", "value": "from a by b; \(rfc2822(arrival)) (UTC; queued)"],
        ]))
        #expect(m?.date == arrival)
        #expect(m?.providerDate == authored)
    }

    @Test("a trailing comment with a quoted-pair after the date still supplies date")
    func trailingQuotedPairReceivedWins() {
        let arrival = wholeSeconds(Date().addingTimeInterval(-3_600))
        let authored = arrival.addingTimeInterval(-40 * 86_400)
        let m = GmailParse.parseMessage(gmailJSON(internalDate: authored, headers: [
            ["name": "Received", "value": "from a by b; \(rfc2822(arrival)) (zone \\) comment; still comment)"],
        ]))
        #expect(m?.date == arrival)
        #expect(m?.providerDate == authored)
    }

    @Test("a two-digit Received year lands in this century, never centuries below internalDate")
    func obsoleteYearReceivedIsNotAncient() {
        let arrival = wholeSeconds(Date().addingTimeInterval(-3_600))
        let authored = arrival.addingTimeInterval(-40 * 86_400)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "d MMM yy HH:mm:ss Z"
        let m = GmailParse.parseMessage(gmailJSON(internalDate: authored, headers: [
            ["name": "Received", "value": "from a by b; \(fmt.string(from: arrival))"],
        ]))
        #expect(m?.date == arrival)
        #expect(m?.providerDate == authored)
    }

    @Test("no Received header: date falls back to internalDate and providerDate matches it")
    func noReceivedFallsBackToInternalDate() {
        let authored = wholeSeconds(Date().addingTimeInterval(-600))
        let m = GmailParse.parseMessage(gmailJSON(internalDate: authored, headers: [
            ["name": "Subject", "value": "draft-like"],
        ]))
        #expect(m?.date == authored)
        #expect(m?.providerDate == authored)
    }

    @Test("unparseable Received header: date falls back to internalDate")
    func malformedReceivedFallsBackToInternalDate() {
        let authored = wholeSeconds(Date().addingTimeInterval(-600))
        let m = GmailParse.parseMessage(gmailJSON(internalDate: authored, headers: [
            ["name": "Received", "value": "by mx.example.com with SMTP id abc"],
        ]))
        #expect(m?.date == authored)
        #expect(m?.providerDate == authored)
    }

    @Test("GmailProvider carries providerDate onto MessageHeaderInfo")
    func providerCarriesProviderDate() async throws {
        let arrival = wholeSeconds(Date().addingTimeInterval(-60))
        let authored = arrival.addingTimeInterval(-30 * 86_400)
        let json = gmailJSON(internalDate: authored, headers: [
            ["name": "Received", "value": "from a by b; \(rfc2822(arrival))"],
        ])
        let data = try JSONSerialization.data(withJSONObject: json)
        let msg = try JSONDecoder().decode(GmailMessage.self, from: data)
        let provider = GmailProvider(userEmail: "user@example.com", accessToken: { _ in "token" })
        let info = await provider.parseGmailMessage(msg)
        #expect(info?.date == arrival)
        #expect(info?.providerDate == authored)
        #expect(info?.providerOrderDate == authored)
    }
}

@Suite("selectStaleHeaders .date window keys on providerDate")
struct StaleWindowProviderDateTests {
    private func daysAgo(_ d: Int) -> Date {
        Date().addingTimeInterval(-Double(d) * 86_400)
    }

    private func info(_ id: String, date: Date, providerDate: Date? = nil) -> MessageHeaderInfo {
        var info = MessageHeaderInfo(
            messageId: id, rfc822MessageId: "<\(id)@example.com>", inReplyTo: nil, references: [],
            threadId: nil, subject: "s", from: "Sender", fromAddress: "sender@example.com",
            to: "to@example.com", cc: "", bcc: "", replyTo: nil, date: date, snippet: "",
            isRead: false, isFlagged: false, hasAttachments: false, isReplied: false,
            isForwarded: false, actionTag: nil
        )
        info.providerDate = providerDate
        return info
    }

    private func header(_ id: String, date: Date, providerDate: Date? = nil) -> MessageHeader {
        MessageHeader(
            messageId: id, subject: "s", from: "Sender", fromAddress: "sender@example.com",
            to: "to@example.com", date: date, snippet: "", folderId: "acc1:INBOX",
            accountId: "acc1", folderPath: "INBOX", isInInbox: true, providerDate: providerDate
        )
    }

    /// INVARIANT: on a `.date` provider, a local row whose PROVIDER key sits
    /// below the fetched page's provider floor is outside the window, however
    /// recent its display date is. The Gmail list message (Received today,
    /// `internalDate` 55 days old) is exactly such a row: Gmail's page of the
    /// newest N by `internalDate` will never contain it, and windowing by the
    /// display date would delete it on the very next full sync. Red on the
    /// pre-`providerDate` code, which compared `date`.
    @Test("recent display date with a below-floor providerDate is NOT stale")
    func belowFloorProviderKeySurvives() {
        let page = [
            info("300", date: daysAgo(1), providerDate: daysAgo(1)),
            info("301", date: daysAgo(3), providerDate: daysAgo(3)),
            info("302", date: daysAgo(5), providerDate: daysAgo(5)),
        ]
        let listMessage = header("150", date: daysAgo(0), providerDate: daysAgo(55))
        let trulyGone = header("299", date: daysAgo(2), providerDate: daysAgo(2))
        let stale = SyncEngine.selectStaleHeaders(
            candidates: [listMessage, trulyGone] + page.map { header($0.messageId, date: $0.date, providerDate: $0.providerDate) },
            fetched: page,
            coverage: FetchCoverage(serverRecordCount: page.count, spansEntireFolder: false, unmaterialisedIds: []),
            windowMode: .date
        )
        let staleIds = Set(stale.map(\.messageId))
        #expect(!staleIds.contains("150"))
        #expect(staleIds.contains("299"))
    }

    /// The floor itself is the page's minimum PROVIDER key, not its minimum
    /// display date: a fetched row whose Received stamp is far older than its
    /// `internalDate` must not drag the floor down and sweep in mid-range rows.
    @Test("the window floor is the fetched page's minimum providerDate")
    func floorIsProviderOrder() {
        let page = [
            info("400", date: daysAgo(1), providerDate: daysAgo(1)),
            // A pathological row: display date 70 days old, provider key 2 days old.
            info("401", date: daysAgo(70), providerDate: daysAgo(2)),
        ]
        let midRange = header("350", date: daysAgo(30), providerDate: daysAgo(30))
        let stale = SyncEngine.selectStaleHeaders(
            candidates: [midRange] + page.map { header($0.messageId, date: $0.date, providerDate: $0.providerDate) },
            fetched: page,
            coverage: FetchCoverage(serverRecordCount: page.count, spansEntireFolder: false, unmaterialisedIds: []),
            windowMode: .date
        )
        #expect(!stale.map(\.messageId).contains("350"))
    }
}
