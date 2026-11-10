/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import Synchronization
@testable import TabMail

// MARK: - A stateful Microsoft Graph calendar

/// An in-memory Graph calendar that applies the documented `event-update`
/// semantics to what the provider sends, so a test can assert on the EVENT the
/// server ends up holding rather than on the request we built:
///
/// - "supply only the values for properties to update. Existing properties that
///   aren't included in the request body maintain their previous values";
/// - "If you update the location property, any prior locations in the locations
///   collection would be removed and replaced by the new location value";
/// - writing a series' `recurrence` (measured against Outlook.com on 2026-11-07):
///   a range written without `recurrenceTimeZone` is stored in UTC, and a rule
///   that differs from the stored one makes Graph restore deleted occurrences
///   and move moved ones back — counted in `seriesResets`. Writing the stored
///   recurrence back exactly changed nothing;
/// - a `recurrence` written without `start` moves the series' start and end to
///   UTC midnight on the range's `startDate` (measured, see `splitSeries`);
/// - a recurrence whose range has no `startDate` is refused with a 400
///   (`recurrenceRange`: "Required");
/// - `$select` returns only the properties it names (`event-get`);
/// - `calendarView` lists single events and occurrences, never a series master
///   (`user-list-calendarview`); this fake lists every stored one, whatever the
///   window, in no particular order;
/// - a body written without an online meeting's join link turns the online
///   meeting off: "Inadvertently removing the meeting blob from the body would
///   disable meeting online" (event-update). Checked live on a work account: a
///   text body write left `isOnlineMeeting` false, `onlineMeetingProvider`
///   `unknown` and `onlineMeeting` null; an HTML write that changed only the
///   notes kept the meeting and its join link.
///
/// Starts and ends are returned as stored, whatever zone `Prefer` names: a
/// fixture stores them as Graph renders them for the device.
final class FakeGraphCalendar: Sendable {
    private let events: Mutex<[String: Data]>
    private let resets = Mutex(0)
    private let patchLog = Mutex<[(id: String, body: Data)]>([])
    private let patchAuthorizationLog = Mutex<[String]>([])
    private let failingRequests = Mutex<[String: [Int]]>([:])

    init(_ seed: [[String: Any]]) {
        var map: [String: Data] = [:]
        for event in seed {
            // swiftlint:disable:next force_try
            map[event["id"] as! String] = try! JSONSerialization.data(withJSONObject: event)
        }
        events = Mutex(map)
    }

    func event(_ id: String) -> [String: Any]? {
        guard let data = events.withLock({ $0[id] }) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    var ids: Set<String> { events.withLock { Set($0.keys) } }

    /// How many writes reset a series' exceptions (see the type's doc).
    var seriesResets: Int { resets.withLock { $0 } }

    /// The next `method` request is answered with `status` and does nothing.
    func failNext(_ method: String, with status: Int) { failingRequests.withLock { $0[method, default: []].append(status) } }

    private func takeFailure(_ method: String) -> Int? {
        failingRequests.withLock { $0[method]?.isEmpty == false ? $0[method]?.removeFirst() : nil }
    }

    /// The PATCH bodies sent for `id`, in order.
    func patches(_ id: String) -> [[String: Any]] {
        patchLog.withLock { $0 }.filter { $0.id == id }
            .compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] }
    }

    /// The `Authorization` header of every PATCH, refused ones included, in order.
    var patchAuthorizations: [String] { patchAuthorizationLog.withLock { $0 } }

    func install(on http: FakeHTTP.Scenario) {
        http.register(path: "/v1.0/me/events/", method: "GET") { [self] request in
            if let status = takeFailure("GET") { return .status(status) }
            let parts = Self.pathParts(request.url)
            let select = Self.selected(request.url)
            if parts.count == 2, parts[1] == "instances" {
                let instances = events.withLock { Array($0.values) }
                    .compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                    .filter { $0["seriesMasterId"] as? String == parts[0] }
                return Self.json(["value": instances.map { Self.only(select, of: $0) }])
            }
            guard parts.count == 1, let stored = event(parts[0]) else { return .status(404) }
            return Self.json(Self.only(select, of: stored))
        }
        http.register(path: "/v1.0/me/calendarView", method: "GET") { [self] request in
            if let status = takeFailure("GET") { return .status(status) }
            let select = Self.selected(request.url)
            let listed = events.withLock { Array($0.values) }
                .compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                .filter { $0["recurrence"] == nil || $0["recurrence"] is NSNull }
            return Self.json(["value": listed.map { Self.only(select, of: $0) }])
        }
        http.register(path: "/v1.0/me/events/", method: "PATCH") { [self] request in
            patchAuthorizationLog.withLock { $0.append(request.header("Authorization") ?? "none") }
            if let status = takeFailure("PATCH") { return .status(status) }
            let parts = Self.pathParts(request.url)
            guard parts.count == 1, var stored = event(parts[0]),
                  let body = request.body,
                  let patch = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  Self.rangeHasStart(patch)
            else { return .status(400) }
            patchLog.withLock { $0.append((id: parts[0], body: body)) }
            if let written = patch["recurrence"],
               Self.canonicalJSON(written) != Self.canonicalJSON(stored["recurrence"]) {
                resets.withLock { $0 += 1 }
            }
            Self.apply(patch, to: &stored)
            store(stored)
            return Self.json(stored)
        }
    }

    private func store(_ event: [String: Any]) {
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: event)
        // swiftlint:disable:next force_cast
        events.withLock { $0[event["id"] as! String] = data }
    }

    private static func apply(_ patch: [String: Any], to stored: inout [String: Any]) {
        for (key, value) in patch { stored[key] = value }
        if patch["recurrence"] != nil, patch["start"] == nil,
           let startDate = ((stored["recurrence"] as? [String: Any])?["range"] as? [String: Any])?["startDate"] as? String {
            let midnight: [String: Any] = ["dateTime": startDate + "T00:00:00.0000000", "timeZone": "UTC"]
            stored["start"] = midnight
            stored["end"] = midnight
        }
        correspondLocations(written: patch, in: &stored)
        defaultRecurrenceZone(in: &stored)
        if let content = (patch["body"] as? [String: Any])?["content"] as? String {
            stored["bodyPreview"] = preview(content)
            if let joinUrl = (stored["onlineMeeting"] as? [String: Any])?["joinUrl"] as? String,
               !content.contains(joinUrl), !content.contains(joinUrl.replacingOccurrences(of: "&", with: "&amp;")) {
                stored["isOnlineMeeting"] = false
                stored["onlineMeetingProvider"] = "unknown"
                stored["onlineMeeting"] = NSNull()
            }
        }
    }

    /// The properties `$select` names, nil when the request has none.
    private static func selected(_ url: URL) -> Set<String>? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "$select" }?.value
            .map { Set($0.split(separator: ",").map(String.init)) }
    }

    private static func only(_ select: Set<String>?, of event: [String: Any]) -> [String: Any] {
        guard let select else { return event }
        return event.filter { select.contains($0.key) }
    }

    /// A written recurrence's range names its `startDate`.
    private static func rangeHasStart(_ written: [String: Any]) -> Bool {
        guard let recurrence = written["recurrence"] as? [String: Any] else { return true }
        return ((recurrence["range"] as? [String: Any])?["startDate"] as? String)?.isEmpty == false
    }

    /// Graph keeps `location` and `locations` corresponding: writing `location` alone
    /// replaces `locations` with it, and writing `locations` alone sets `location` from
    /// them (modelled here as the first entry, as in the fixture).
    private static func correspondLocations(written: [String: Any], in stored: inout [String: Any]) {
        if let location = written["location"], written["locations"] == nil {
            stored["locations"] = [location]
        } else if written["location"] == nil, let locations = written["locations"] as? [Any] {
            stored["location"] = locations.first
        }
    }

    /// A recurrence written without `recurrenceTimeZone` is stored in UTC.
    private static func defaultRecurrenceZone(in stored: inout [String: Any]) {
        guard var recurrence = stored["recurrence"] as? [String: Any],
              var range = recurrence["range"] as? [String: Any], range["recurrenceTimeZone"] == nil
        else { return }
        range["recurrenceTimeZone"] = "UTC"
        recurrence["range"] = range
        stored["recurrence"] = recurrence
    }

    private static func canonicalJSON(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
        else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func preview(_ content: String) -> String {
        String(content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).prefix(255))
    }

    /// Path components after `/v1.0/me/events/`.
    private static func pathParts(_ url: URL) -> [String] {
        let components = url.pathComponents
        guard let index = components.firstIndex(of: "events") else { return [] }
        return Array(components[(index + 1)...])
    }

    private static func json(_ object: [String: Any]) -> FakeHTTP.CannedResponse {
        // swiftlint:disable:next force_try
        .raw(statusCode: 200, headers: ["Content-Type": "application/json"],
             body: try! JSONSerialization.data(withJSONObject: object))
    }
}

// MARK: - Fixtures

enum GraphFixture {
    static let utc = TimeZone(identifier: "UTC")!

    /// A week from today, so no fixture date goes stale, at the UTC time that
    /// puts the device on the same date: noon less half the device's offset,
    /// which is between about 06:00 and 19:00 on the device at any offset from
    /// -12 to +14 hours. The fixture stores starts in UTC and its series' day in
    /// that frame, so no test depends on the host's zone.
    static let start: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let day = cal.startOfDay(for: Date().addingTimeInterval(7 * 86_400))
        let halfOffset = TimeZone.current.secondsFromGMT(for: day) / 2 / 900 * 900
        return day.addingTimeInterval(Double(12 * 3_600 - halfOffset))
    }()

    static let occurrenceStart = start.addingTimeInterval(7 * 86_400)

    static func naive(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = utc
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fmt.string(from: date)
    }

    static func rfc3339(_ date: Date) -> String { naive(date) + "Z" }

    /// The date `date` falls on in UTC and on the device.
    static func utcDay(_ date: Date) -> String { String(naive(date).prefix(10)) }
    static func deviceDay(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    /// An hour either side of a UTC midnight a week ahead: two UTC dates, and one
    /// device date unless the device is within about an hour of UTC.
    static let acrossUTCMidnight: (from: Date, to: Date) = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let midnight = cal.startOfDay(for: Date().addingTimeInterval(8 * 86_400))
        return (midnight.addingTimeInterval(-3_600), midnight.addingTimeInterval(3_600))
    }()
    static var acrossUTCMidnightIsOneDeviceDay: Bool {
        deviceDay(acrossUTCMidnight.from) == deviceDay(acrossUTCMidnight.to)
    }

    /// An hour either side of the device's midnight a week ahead: two device
    /// dates, and one UTC date unless the device is within about an hour of UTC.
    static let acrossDeviceMidnight: (from: Date, to: Date) = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let midnight = cal.startOfDay(for: Date().addingTimeInterval(8 * 86_400))
        return (midnight.addingTimeInterval(-3_600), midnight.addingTimeInterval(3_600))
    }()
    static var acrossDeviceMidnightIsOneUTCDay: Bool {
        utcDay(acrossDeviceMidnight.from) == utcDay(acrossDeviceMidnight.to)
    }

    /// A weekly series starting at `start`, its range dated on the device's day,
    /// as Graph keeps it in a recurrence zone that is the device's.
    static func seriesOnDeviceDay(id: String, start: Date) -> [String: Any] {
        var e = event(id: id, start: start, online: false, recurring: true)
        var recurrence = e["recurrence"] as? [String: Any] ?? [:]
        var range = recurrence["range"] as? [String: Any] ?? [:]
        range["startDate"] = deviceDay(start)
        recurrence["range"] = range
        e["recurrence"] = recurrence
        return e
    }

    /// A zone 14 hours ahead of UTC with no daylight saving time. A wall time
    /// in it, spelled with a UTC offset, reads as an instant 14 hours later
    /// than the wall time in it.
    static let farEast = "Pacific/Kiritimati"

    /// `hour`:00 on the device, `days` after the device's date eight days ahead.
    static func onDevice(days: Int, hour: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let base = cal.startOfDay(for: Date().addingTimeInterval(8 * 86_400))
        let day = cal.date(byAdding: .day, value: days, to: base)!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    /// `date`'s wall time in `zone`, without an offset.
    static func wall(_ date: Date, in zone: String) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: zone)!
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fmt.string(from: date)
    }

    /// The device's date of the start Graph stores as `wall` in `zone`, written
    /// with or without seconds.
    static func deviceDay(wall: String, in zone: String) -> String? {
        guard let tz = TimeZone(identifier: zone) else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = tz
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let instant = fmt.date(from: String(wall.prefix(19))) { return deviceDay(instant) }
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return fmt.date(from: String(wall.prefix(16))).map(deviceDay)
    }

    static func weekday(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        return names[cal.component(.weekday, from: date) - 1]
    }

    static var attendees: [[String: Any]] { [
        ["emailAddress": ["address": "ana@example.com", "name": "Ana"], "type": "required", "status": ["response": "accepted"]],
        ["emailAddress": ["address": "bo@example.com", "name": "Bo"], "type": "optional", "status": ["response": "tentativelyAccepted"]],
        ["emailAddress": ["address": "room-1@example.com", "name": "Room 1"], "type": "resource", "status": ["response": "accepted"]],
    ] }

    /// An online meeting's join link (`onlineMeeting.joinUrl`): the long
    /// `meetup-join` form, which a Teams join section holds on its "System
    /// reference" link, after the short "Join:" link.
    static let joinUrl = "https://meet.example.com/l/meetup-join/19%3ameeting_123/0?context=a&lang=en"
    /// The short link a Teams join section shows first ("Join:").
    static let shortJoinUrl = "https://meet.example.com/meet/0000000000?p=PLACEHOLDER"

    /// A line of underscores that opens and closes a Teams join section.
    static let joinSeparator = "<div aria-hidden=\"true\" style=\"margin-bottom:24px; overflow:hidden; white-space:nowrap\">\r\n"
        + String(repeating: "_", count: 80) + "</div>\r\n"

    /// An online meeting's join section as Graph stored it for a meeting made in
    /// Teams on a work account (checked live, #555), every link, id, number and
    /// passcode a placeholder: an outer `<div>` opening with three `<br>`, then
    /// the Teams block, which starts and ends with a line of underscores.
    static let joinSection = "<div><br>\r\n<br>\r\n<br>\r\n"
        + "<div class=\"me-email-text\" lang=\"en-GB\" style=\"max-width:1024px; color:#242424; font-family:'Segoe UI','Helvetica Neue',Helvetica,Arial,sans-serif\">\r\n"
        + joinSeparator
        + "<div style=\"margin-bottom:12px\"><span class=\"me-email-text\" style=\"font-size:20px; color:#242424; font-weight:600\">Microsoft Teams meeting</span>\r\n</div>\r\n"
        + "<div style=\"margin-bottom:6px\"><span class=\"me-email-text\" style=\"font-size:20px; color:#242424; font-weight:600\">Join:\r\n</span><a href=\""
        + shortJoinUrl + "\" id=\"meet_invite_block.action.join_link\" title=\"Meeting join\" aria-label=\"Meeting join\" class=\"me-email-link\" style=\"font-size:20px; text-decoration:underline; color:#5B5FC7\">"
        + shortJoinUrl + "</a>\r\n</div>\r\n"
        + "<div style=\"margin-bottom:6px\"><span class=\"me-email-text-secondary\" style=\"font-size:14px; color:#616161\">Meeting ID:\r\n</span><span class=\"me-email-text\" style=\"font-size:14px; color:#242424\">000 000 000 000</span>\r\n</div>\r\n"
        + "<div style=\"margin-bottom:32px\"><span class=\"me-email-text-secondary\" style=\"font-size:14px; color:#616161\">Passcode:\r\n</span><span class=\"me-email-text\" style=\"font-size:14px; color:#242424\">PASSCODE</span>\r\n</div>\r\n"
        + "<div style=\"margin-bottom:12px; max-width:1024px\">\r\n<hr style=\"border:0; background:#616161; height:1px\">\r\n</div>\r\n"
        + "<div style=\"margin-bottom:24px\"><a href=\"https://help.example.com/join\" id=\"meet_invite_block.action.help\" class=\"me-email-link\" style=\"font-size:14px; text-decoration:underline; color:#5B5FC7\">Need help?</a>\r\n"
        + "<span style=\"color:#616161\">|</span> <a href=\"" + joinUrl.replacingOccurrences(of: "&", with: "&amp;")
        + "\" id=\"meet_invite_block.action.join_link_compatibility\" class=\"me-email-link\" style=\"font-size:14px; text-decoration:underline; color:#5B5FC7\">\r\nSystem reference</a> </div>\r\n"
        + "<div><span class=\"me-email-text-secondary\" style=\"font-size:14px; color:#616161\">For organisers:\r\n</span><a href=\"https://meet.example.com/meetingOptions/?organizerId=ORGANIZER&amp;tenantId=TENANT&amp;threadId=THREAD&amp;messageId=0&amp;language=en-GB\" id=\"meet_invite_block.action.organizer_meet_options\" class=\"me-email-link\" style=\"font-size:14px; text-decoration:underline; color:#5B5FC7\">Meeting\r\n options</a> </div>\r\n"
        + "<div style=\"margin-top:24px; margin-bottom:6px\"></div>\r\n<div style=\"margin-bottom:24px\"></div>\r\n"
        + joinSeparator
        + "</div>\r\n</div>\r\n"

    /// The join section of Graph's online-meeting samples
    /// (learn.microsoft.com/en-us/graph/outlook-calendar-online-meetings, the
    /// create and update responses), an older Teams layout, with placeholders:
    /// a line of underscores in a `<span>`, the join link, dial-in details, and
    /// the line again.
    static let sampleJoinSection = sampleJoinSeparator
        + "<div class=\"me-email-text\" style=\"color:#252424; font-family:'Segoe UI','Helvetica Neue',Helvetica,Arial,sans-serif\">\r\n"
        + "<div style=\"margin-top:24px; margin-bottom:10px\"><a class=\"me-email-headline\" href=\""
        + joinUrl.replacingOccurrences(of: "&", with: "&amp;")
        + "\" target=\"_blank\" rel=\"noreferrer noopener\" style=\"font-size:18px; font-family:'Segoe UI Semibold','Segoe UI','Helvetica Neue',Helvetica,Arial,sans-serif; text-decoration:underline; color:#6264a7\">Join\r\n Microsoft Teams Meeting</a> </div>\r\n"
        + "<div>\r\n<div><a class=\"me-email-link\" href=\"tel:&#43;1 555-0100,,000000000# \" target=\"_blank\" rel=\"noreferrer noopener\" style=\"font-size:14px; text-decoration:none; color:#6264a7\">&#43;1 555-0100</a>\r\n"
        + "<span style=\"font-size:12px\">&nbsp; Placeholder City (Toll) </span></div>\r\n</div>\r\n"
        + "<div style=\"margin-top:10px; margin-bottom:20px\"><span style=\"font-size:12px\">Conference ID:\r\n</span><span style=\"font-size:14px\">000 000 000# </span></div>\r\n"
        + "<div style=\"margin-bottom:24px\"><a class=\"me-email-link\" target=\"_blank\" href=\"https://dialin.example.com/conference?id=000000000\" rel=\"noreferrer noopener\" style=\"font-size:12px; text-decoration:none; color:#6264a7\">Local\r\n numbers</a>"
        + " | <a class=\"me-email-link\" target=\"_blank\" href=\"https://settings.example.com/pstnconferencing\" rel=\"noreferrer noopener\" style=\"font-size:12px; text-decoration:none; color:#6264a7\">\r\nReset PIN</a>"
        + " | <a class=\"me-email-link\" target=\"_blank\" href=\"https://help.example.com/join\" rel=\"noreferrer noopener\" style=\"font-size:12px; text-decoration:none; color:#6264a7\">\r\nLearn more about Teams</a>"
        + " | <a class=\"me-email-link\" target=\"_blank\" href=\"https://meet.example.com/meetingOptions/?organizerId=ORGANIZER&amp;tenantId=TENANT&amp;threadId=THREAD&amp;messageId=0&amp;language=en-US\" rel=\"noreferrer noopener\" style=\"font-size:12px; text-decoration:none; color:#6264a7\">\r\nMeeting options</a> </div>\r\n"
        + "<div style=\"font-size:14px; margin-bottom:4px\"></div>\r\n<div style=\"font-size:12px\"></div>\r\n</div>\r\n"
        + sampleJoinSeparator
    static let sampleJoinSeparator = "<div style=\"width:100%; height:20px\"><span style=\"white-space:nowrap; color:gray; opacity:.36\">"
        + String(repeating: "_", count: 80) + "</span>\r\n</div>\r\n"

    /// The document around a body's content, as Graph stores it.
    static let htmlHead = "<html>\r\n<head>\r\n<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">\r\n</head>\r\n<body>\r\n"
    static let htmlTail = "</body>\r\n</html>\r\n"

    /// An online meeting's body: notes in HTML with a link and text past the
    /// 255-character preview, then the join section.
    static let onlineBody = htmlHead
        + "<p>Agenda with a <a href=\"https://example.com/doc\" title=\"https://example.com/doc\">\r\nlinked doc</a></p>\r\n<p>"
        + String(repeating: "Long notes past the preview. ", count: 12) + "</p>\r\n"
        + joinSection + htmlTail

    static let plainBody = "<p>Agenda with <b>bold</b> notes and a <a href=\"https://example.com/doc\">link</a></p>"

    static func event(
        id: String,
        start: Date = start,
        online: Bool = true,
        recurring: Bool = false,
        seriesMasterId: String? = nil,
        allDay: Bool = false
    ) -> [String: Any] {
        var e: [String: Any] = [
            "id": id,
            "subject": "Planning",
            "body": ["contentType": "html", "content": online ? onlineBody : plainBody],
            "bodyPreview": "Agenda with a linked doc",
            "isOnlineMeeting": online,
            "onlineMeetingProvider": online ? "teamsForBusiness" : "unknown",
            "showAs": "tentative",
            "location": ["displayName": "Room A"],
            "locations": [["displayName": "Room A"], ["displayName": "Room B"]],
            "attendees": attendees,
            "start": ["dateTime": naive(start), "timeZone": "UTC"],
            "end": ["dateTime": naive(start.addingTimeInterval(1_800)), "timeZone": "UTC"],
            "isAllDay": false,
            "organizer": ["emailAddress": ["address": "me@example.com", "name": "Me"]],
        ]
        if online { e["onlineMeeting"] = ["joinUrl": joinUrl] }
        if allDay {
            let day = String(naive(start).prefix(10))
            let next = String(naive(start.addingTimeInterval(86_400)).prefix(10))
            e["start"] = ["dateTime": day + "T00:00:00.0000000", "timeZone": "UTC"]
            e["end"] = ["dateTime": next + "T00:00:00.0000000", "timeZone": "UTC"]
            e["isAllDay"] = true
        }
        if recurring {
            // As Graph stores it: every field, the unused ones at their defaults,
            // and a zone other than UTC, so a write that drops it (which Graph
            // stores as UTC) shows.
            e["recurrence"] = [
                "pattern": ["type": "weekly", "interval": 1, "month": 0, "dayOfMonth": 0, "daysOfWeek": [weekday(start)],
                            "firstDayOfWeek": "monday", "index": "first"],
                "range": ["type": "noEnd", "startDate": String(naive(start).prefix(10)), "endDate": "0001-01-01",
                          "recurrenceTimeZone": "Pacific Standard Time", "numberOfOccurrences": 0],
            ]
        }
        if let seriesMasterId { e["seriesMasterId"] = seriesMasterId }
        return e
    }

    static func calendar() -> FakeGraphCalendar {
        FakeGraphCalendar([
            event(id: "ev-online"),
            event(id: "ev-plain", online: false),
            event(id: "ser-1", recurring: true),
            event(id: "ser-1-occ-2", start: occurrenceStart, seriesMasterId: "ser-1"),
        ])
    }
}

// MARK: - The edits

/// One user edit, the patch the calendar queue builds for it, and the event
/// properties it is allowed to change. Everything else must come back exactly
/// as it was.
enum UserCalendarEdit: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case rename, moveOneHour, endLater, moveRoom, addAttendee, removeAttendee, markBusy, newDescription, newRecurrence

    var testDescription: String { rawValue }

    /// The edits the online-meeting fixtures take: every edit but a new rule,
    /// which only a series takes.
    static let ofAnOnlineMeeting: [UserCalendarEdit] = [
        .rename, .moveOneHour, .endLater, .moveRoom, .addAttendee, .removeAttendee, .markBusy, .newDescription,
    ]

    static let newDescriptionText = "New notes\nSecond line"
    static let newRoom = "Room 5"
    static let removedAttendee = "bo@example.com"

    func patch(start: Date) -> GCalEventInput {
        var p = GCalEventInput()
        switch self {
        case .rename:
            p.summary = "Planning (renamed)"
        case .moveOneHour:
            p.startDateTime = GraphFixture.rfc3339(start.addingTimeInterval(3_600))
            p.startTimeZone = "UTC"
        case .endLater:
            // "make it end an hour later": the end alone.
            p.endDateTime = GraphFixture.rfc3339(start.addingTimeInterval(1_800 + 3_600))
            p.endTimeZone = "UTC"
        case .moveRoom:
            p.location = Self.newRoom
        case .addAttendee:
            // What `resolveAttendeeDelta` hands the provider: the whole resolved list.
            p.attendees = [
                (email: "ana@example.com", name: "Ana"),
                (email: "bo@example.com", name: "Bo"),
                (email: "room-1@example.com", name: "Room 1"),
                (email: "cy@example.com", name: "Cy"),
            ]
        case .removeAttendee:
            // "take Bo off it": the whole resolved list, without Bo.
            p.attendees = [
                (email: "ana@example.com", name: "Ana"),
                (email: "room-1@example.com", name: "Room 1"),
            ]
        case .markBusy:
            p.transparency = "opaque"
        case .newDescription:
            p.description = Self.newDescriptionText
        case .newRecurrence:
            p.recurrence = ["RRULE:FREQ=DAILY;COUNT=5"]
        }
        return p
    }

    /// Graph properties this edit is allowed to change.
    var changes: Set<String> {
        switch self {
        case .rename: ["subject"]
        case .moveOneHour: ["start", "end", "isAllDay"]
        // The start is written beside the end, at the same instant (asserted;
        // whether it should shift instead is #542).
        case .endLater: ["start", "end", "isAllDay"]
        case .moveRoom: ["location", "locations"]
        case .addAttendee, .removeAttendee: ["attendees"]
        case .markBusy: ["showAs"]
        case .newDescription: ["body", "bodyPreview"]
        case .newRecurrence: ["recurrence"]
        }
    }
}

/// A whole series at 10:00 on the device, moved by a start the tools pass
/// through as given: spelled with a UTC offset, labelled with
/// `GraphFixture.farEast`. Read as an instant, each new start falls on the
/// wrong side of a device midnight.
enum OffsetSpelledMove: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case laterSameDay, eveningBefore, nextDay

    var testDescription: String { rawValue }

    /// Where the user moved the series, on the device.
    var newStart: Date {
        switch self {
        case .laterSameDay: GraphFixture.onDevice(days: 0, hour: 11)
        case .eveningBefore: GraphFixture.onDevice(days: -1, hour: 20)
        case .nextDay: GraphFixture.onDevice(days: 1, hour: 11)
        }
    }

    var movesDate: Bool { self != .laterSameDay }
}

/// How the tools may spell that new start and pass it through as given: with a
/// UTC offset, or without seconds (bare or with `Z`).
enum StartSpelling: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case z = "Z", fractionZ = ".000Z", plusZero = "+00:00", noSeconds = "HH:mm", noSecondsZ = "HH:mmZ"

    var testDescription: String { rawValue }

    /// `wall` (`yyyy-MM-dd'T'HH:mm:ss`) spelled this way.
    func spell(_ wall: String) -> String {
        switch self {
        case .z, .fractionZ, .plusZero: wall + rawValue
        case .noSeconds: String(wall.prefix(16))
        case .noSecondsZ: String(wall.prefix(16)) + "Z"
        }
    }
}

/// Every property a user can see on an Outlook event and an edit must not touch
/// unless it is the one edited.
private let watchedProperties = [
    "subject", "body", "bodyPreview", "isOnlineMeeting", "onlineMeetingProvider", "onlineMeeting", "showAs", "location",
    "locations", "attendees", "start", "end", "isAllDay", "recurrence",
]

private func canonical(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "null" }
    guard JSONSerialization.isValidJSONObject([value]),
          let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
    else { return "\(value)" }
    return String(decoding: data, as: UTF8.self)
}

/// email → attendee type.
private func attendeeTypes(_ event: [String: Any]) -> [String: String] {
    var out: [String: String] = [:]
    for attendee in event["attendees"] as? [[String: Any]] ?? [] {
        guard let email = (attendee["emailAddress"] as? [String: Any])?["address"] as? String else { continue }
        out[email.lowercased()] = attendee["type"] as? String ?? "?"
    }
    return out
}

/// Asserts a description edit wrote `notes`: as the text body of an event that is
/// no online meeting; for an online meeting, in place of the stored notes, with
/// the join section and everything after it as stored, and the meeting on.
private func expectNewNotes(_ notes: String, before: [String: Any], after: [String: Any], label: String) {
    let body = after["body"] as? [String: Any]
    guard before["onlineMeeting"] is [String: Any] else {
        #expect(body?["contentType"] as? String == "text", "\(label): the description was not written as text")
        #expect(body?["content"] as? String == notes, "\(label): the description written is \(body?["content"] ?? "none")")
        return
    }
    let was = (before["body"] as? [String: Any])?["content"] as? String ?? ""
    let content = body?["content"] as? String ?? ""
    let section = was.range(of: GraphFixture.joinSection).map { String(was[$0.lowerBound...]) }
    #expect(section != nil, "\(label): the fixture holds no join section")
    #expect(body?["contentType"] as? String == "html", "\(label): the online meeting's body is not HTML")
    #expect(section.map(content.hasSuffix) == true, "\(label): the join section was not kept as stored")
    #expect(content.hasPrefix(GraphFixture.htmlHead), "\(label): the document before the notes was not kept")
    let html = notes.replacingOccurrences(of: "\n", with: "<br>\r\n")
    // The notes start after `<body>`, so the head's closing line break is the one written before them.
    #expect(content == GraphFixture.htmlHead + html + "\r\n" + (section ?? ""),
            "\(label): the notes were not replaced by the new ones alone")
    #expect(after["isOnlineMeeting"] as? Bool == true, "\(label): the edit turned the online meeting off")
}

/// Asserts `after` equals `before` on every watched property `edit` does not change,
/// and that the property it edits holds what the edit asked for (`start` is the
/// edited event's start). For an attendee edit, every attendee that stays keeps
/// its type, and the one removed is gone.
private func expectOnlyEdited(
    _ edit: UserCalendarEdit?, before: [String: Any], after: [String: Any], start: Date? = nil, label: String
) {
    for property in watchedProperties where !(edit?.changes.contains(property) ?? false) {
        #expect(canonical(after[property]) == canonical(before[property]),
                "\(label): \(edit?.rawValue ?? "no edit") changed \(property), which it did not edit")
    }
    switch edit {
    case .rename:
        #expect(after["subject"] as? String == "Planning (renamed)", "\(label): the new subject was not written")
    case .markBusy:
        #expect(after["showAs"] as? String == "busy", "\(label): the event was not marked busy")
    case .moveOneHour:
        if let start {
            let newStart = (after["start"] as? [String: Any])?["dateTime"] as? String
            let newEnd = (after["end"] as? [String: Any])?["dateTime"] as? String
            #expect(newStart?.hasPrefix(GraphFixture.naive(start.addingTimeInterval(3_600))) == true,
                    "\(label): the start did not move an hour, is \(newStart ?? "none")")
            #expect(newEnd?.hasPrefix(GraphFixture.naive(start.addingTimeInterval(1_800 + 3_600))) == true,
                    "\(label): the end did not move with the start, is \(newEnd ?? "none")")
        }
    case .endLater:
        if let start {
            let newStart = (after["start"] as? [String: Any])?["dateTime"] as? String
            let newEnd = (after["end"] as? [String: Any])?["dateTime"] as? String
            #expect(newStart?.hasPrefix(GraphFixture.naive(start)) == true,
                    "\(label): moving the end moved the start, is \(newStart ?? "none")")
            #expect(newEnd?.hasPrefix(GraphFixture.naive(start.addingTimeInterval(1_800 + 3_600))) == true,
                    "\(label): the end did not move an hour later, is \(newEnd ?? "none")")
        }
    case .moveRoom:
        let room: [String: Any] = ["displayName": UserCalendarEdit.newRoom]
        #expect(canonical(after["location"]) == canonical(room), "\(label): the new room was not written")
        #expect(canonical(after["locations"]) == canonical([room]), "\(label): the locations do not name only the new room")
    case .newDescription:
        expectNewNotes(UserCalendarEdit.newDescriptionText, before: before, after: after, label: label)
    case .newRecurrence:
        let recurrence = after["recurrence"] as? [String: Any]
        #expect((recurrence?["pattern"] as? [String: Any])?["type"] as? String == "daily", "\(label): the new rule was not written")
        let range = recurrence?["range"] as? [String: Any]
        #expect(range?["type"] as? String == "numbered" && (range?["numberOfOccurrences"] as? Int) == 5,
                "\(label): the new rule's count was not written")
        let wasRange = (before["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        #expect(range?["startDate"] as? String == wasRange?["startDate"] as? String,
                "\(label): a rule change moved the range's start date")
    default:
        break
    }
    if edit == .addAttendee || edit == .removeAttendee {
        let was = attendeeTypes(before)
        let now = attendeeTypes(after)
        let removed = edit == .removeAttendee ? UserCalendarEdit.removedAttendee : nil
        for (email, type) in was where email != removed {
            #expect(now[email] == type, "\(label): attendee \(email) was \(type), is \(now[email] ?? "gone")")
        }
        if let removed {
            #expect(was[removed] != nil && now[removed] == nil, "\(label): the removed attendee is \(now[removed] ?? "gone")")
            #expect(now.count == was.count - 1, "\(label): \(now.count) attendees after removing one of \(was.count)")
        } else {
            #expect(now["cy@example.com"] == "required", "\(label): the added attendee is \(now["cy@example.com"] ?? "missing")")
        }
    }
}

/// A provider whose sign-in hands out "stale-token" until it is asked to refresh.
private func makeProvider(_ http: FakeHTTP.Scenario) -> ExchangeCalendarProvider {
    ExchangeCalendarProvider(mailbox: "calendar@example.com",
                             accessToken: { forceRefresh in forceRefresh ? "fresh-token" : "stale-token" },
                             session: http.session)
}

// MARK: - The invariant

@Suite("Outlook calendar edits change only what the user edited", .serialized)
struct ExchangeCalendarEditPreservationTests {

    @Test("an edit of a single event leaves every property it did not edit as it was",
          arguments: UserCalendarEdit.ofAnOnlineMeeting)
    func singleEvent(_ edit: UserCalendarEdit) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let before = try #require(graph.event("ev-online"))

        _ = try await makeProvider(http).updateEvent(eventId: "ev-online", event: edit.patch(start: GraphFixture.start))

        let after = try #require(graph.event("ev-online"))
        expectOnlyEdited(edit, before: before, after: after, start: GraphFixture.start, label: "single event")
        #expect(graph.ids == GraphFixture.calendar().ids, "an edit created or removed an event")
    }

    @Test("a description edit writes the text and nothing else")
    func plainDescription() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let before = try #require(graph.event("ev-plain"))

        _ = try await makeProvider(http).updateEvent(
            eventId: "ev-plain", event: UserCalendarEdit.newDescription.patch(start: GraphFixture.start))

        let after = try #require(graph.event("ev-plain"))
        expectOnlyEdited(.newDescription, before: before, after: after, label: "plain event")
        let body = try #require(after["body"] as? [String: Any])
        #expect(body["contentType"] as? String == "text")
        #expect(body["content"] as? String == UserCalendarEdit.newDescriptionText)
    }

    @Test("an edit of a whole series leaves every property it did not edit as it was",
          arguments: UserCalendarEdit.ofAnOnlineMeeting + [.newRecurrence])
    func wholeSeries(_ edit: UserCalendarEdit) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let before = try #require(graph.event("ser-1"))

        _ = try await makeProvider(http).updateEvent(eventId: "ser-1", event: edit.patch(start: GraphFixture.start))

        let after = try #require(graph.event("ser-1"))
        expectOnlyEdited(edit, before: before, after: after, start: GraphFixture.start, label: "series")
    }

    /// #423: any recurrence write that differs from the stored one makes Graph
    /// restore deleted occurrences and move moved ones back. So an edit of a
    /// whole series that gives no rule and keeps the series' date (a rename, a
    /// time change on the same day, an attendee or availability change) sends
    /// no `recurrence` at all.
    @Test("an edit of a whole series that gives no rule writes no recurrence",
          arguments: UserCalendarEdit.ofAnOnlineMeeting)
    func wholeSeriesKeepsRule(_ edit: UserCalendarEdit) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)

        _ = try await makeProvider(http).updateEvent(eventId: "ser-1", event: edit.patch(start: GraphFixture.start))

        let sent = graph.patches("ser-1")
        #expect(sent.count == 1, "\(edit.rawValue): \(sent.count) PATCHes")
        #expect(sent.allSatisfy { $0["recurrence"] == nil }, "\(edit.rawValue): the PATCH carried a recurrence")
        #expect(graph.seriesResets == 0, "\(edit.rawValue): the edit reset the series' exceptions")
    }

    /// A whole series moved to start a week later: the range's `startDate` must
    /// follow the start, so the stored recurrence is written with only that date
    /// moved. Its pattern, zone and first day of the week stay.
    @Test("a whole series moved to another date keeps its recurrence but for the range's start date")
    func wholeSeriesMovesToAnotherDate() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let before = try #require(graph.event("ser-1"))
        let newStart = GraphFixture.start.addingTimeInterval(7 * 86_400)
        var patch = GCalEventInput()
        patch.startDateTime = GraphFixture.rfc3339(newStart)
        patch.startTimeZone = "UTC"

        _ = try await makeProvider(http).updateEvent(eventId: "ser-1", event: patch)

        let after = try #require(graph.event("ser-1"))
        #expect(graph.patches("ser-1").contains { $0["recurrence"] != nil }, "the range's start date was not moved")
        let was = try #require(before["recurrence"] as? [String: Any])
        let now = try #require(after["recurrence"] as? [String: Any])
        #expect(canonical(now["pattern"]) == canonical(was["pattern"]), "the move changed the pattern")
        var range = try #require(now["range"] as? [String: Any])
        #expect(range["startDate"] as? String == String(GraphFixture.naive(newStart).prefix(10)))
        range["startDate"] = (was["range"] as? [String: Any])?["startDate"]
        #expect(canonical(range) == canonical(was["range"]), "the move changed the range beyond its start date")
        let start = try #require(after["start"] as? [String: Any])
        #expect((start["dateTime"] as? String)?.hasPrefix(GraphFixture.naive(newStart)) == true, "the series did not move")
        for property in watchedProperties where !["start", "end", "recurrence"].contains(property) {
            #expect(canonical(after[property]) == canonical(before[property]), "the move changed \(property)")
        }
    }

    /// "make it daily from next week": the user's rule is written, not the stored
    /// one, and its range starts on the new date.
    @Test("a whole series given a new rule and a new date gets the new rule from that date")
    func wholeSeriesNewRuleAndDate() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let newStart = GraphFixture.start.addingTimeInterval(7 * 86_400)
        var patch = UserCalendarEdit.newRecurrence.patch(start: GraphFixture.start)
        patch.startDateTime = GraphFixture.rfc3339(newStart)
        patch.startTimeZone = "UTC"

        _ = try await makeProvider(http).updateEvent(eventId: "ser-1", event: patch)

        let after = try #require(graph.event("ser-1"))
        let recurrence = try #require(after["recurrence"] as? [String: Any])
        #expect((recurrence["pattern"] as? [String: Any])?["type"] as? String == "daily", "the stored rule was written over the new one")
        let range = recurrence["range"] as? [String: Any]
        #expect(range?["type"] as? String == "numbered" && (range?["numberOfOccurrences"] as? Int) == 5)
        #expect(range?["startDate"] as? String == GraphFixture.utcDay(newStart))
        #expect(((after["start"] as? [String: Any])?["dateTime"] as? String)?.hasPrefix(GraphFixture.naive(newStart)) == true)
    }

    /// The date a series starts on is the device's (`request` asks Graph for starts
    /// in the device's zone), not UTC's. A move within the device's day that
    /// crosses UTC midnight is not a date move.
    @Test("a series moved within the device's day across UTC midnight writes no recurrence",
          .enabled(if: GraphFixture.acrossUTCMidnightIsOneDeviceDay))
    func seriesMovedAcrossUTCMidnight() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let (from, to) = GraphFixture.acrossUTCMidnight
        let graph = FakeGraphCalendar([GraphFixture.seriesOnDeviceDay(id: "ser-x", start: from)])
        graph.install(on: http)
        var patch = GCalEventInput()
        patch.startDateTime = GraphFixture.rfc3339(to)
        patch.startTimeZone = "UTC"

        _ = try await makeProvider(http).updateEvent(eventId: "ser-x", event: patch)

        let sent = graph.patches("ser-x")
        #expect(sent.count == 1 && sent.allSatisfy { $0["recurrence"] == nil }, "a move within the device's day wrote a recurrence")
        #expect(graph.seriesResets == 0)
        #expect(((graph.event("ser-x")?["start"] as? [String: Any])?["dateTime"] as? String)?.hasPrefix(GraphFixture.naive(to)) == true)
    }

    /// The other side: a move across the device's midnight within one UTC date is a
    /// date move, and the range's start date is the device's new date.
    @Test("a series moved across the device's midnight moves its range's start date to the device's date",
          .enabled(if: GraphFixture.acrossDeviceMidnightIsOneUTCDay))
    func seriesMovedAcrossDeviceMidnight() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let (from, to) = GraphFixture.acrossDeviceMidnight
        let graph = FakeGraphCalendar([GraphFixture.seriesOnDeviceDay(id: "ser-y", start: from)])
        graph.install(on: http)
        var patch = GCalEventInput()
        patch.startDateTime = GraphFixture.rfc3339(to)
        patch.startTimeZone = "UTC"

        _ = try await makeProvider(http).updateEvent(eventId: "ser-y", event: patch)

        let range = (graph.event("ser-y")?["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        #expect(graph.patches("ser-y").contains { $0["recurrence"] != nil }, "a move to the device's next day kept the old range start")
        #expect(range?["startDate"] as? String == GraphFixture.deviceDay(to))
    }

    /// The tools pass a start they cannot read through as given, so a start can
    /// arrive without an offset or seconds (`…T10:00`). It is read like any other
    /// start: the wall time in its label, dated on the device.
    @Test("a whole series moved to another date by a start written without an offset keeps its recurrence at the new date")
    func wholeSeriesMovedByNaiveStart() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let before = try #require(graph.event("ser-1"))
        let newStart = GraphFixture.start.addingTimeInterval(7 * 86_400)
        var patch = GCalEventInput()
        patch.startDateTime = String(GraphFixture.naive(newStart).prefix(16))
        patch.startTimeZone = "UTC"
        patch.endDateTime = String(GraphFixture.naive(newStart.addingTimeInterval(1_800)).prefix(16))
        patch.endTimeZone = "UTC"

        _ = try await makeProvider(http).updateEvent(eventId: "ser-1", event: patch)

        let after = try #require(graph.event("ser-1"))
        let now = try #require(after["recurrence"] as? [String: Any], "the series lost its recurrence")
        #expect(graph.patches("ser-1").contains { $0["recurrence"] != nil }, "the range's start date was not moved")
        #expect((now["range"] as? [String: Any])?["startDate"] as? String == GraphFixture.utcDay(newStart))
        #expect(canonical(now["pattern"]) == canonical((before["recurrence"] as? [String: Any])?["pattern"]), "the move changed the pattern")
    }

    /// The tools pass a start spelled with an offset, or without seconds, through
    /// as given and label it with the edit's zone, and Graph stores the wall time
    /// in that zone. The series' date is that stored start's, read on the device:
    /// a move within the device's day writes no recurrence, and a move to another
    /// day writes the range at that day.
    @Test("a series moved by a start spelled with an offset or without seconds is dated where Graph stores it",
          arguments: OffsetSpelledMove.allCases, StartSpelling.allCases)
    func seriesMovedByOffsetSpelledStart(_ move: OffsetSpelledMove, _ spelling: StartSpelling) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let seriesStart = GraphFixture.onDevice(days: 0, hour: 10)
        let graph = FakeGraphCalendar([GraphFixture.seriesOnDeviceDay(id: "ser-z", start: seriesStart)])
        graph.install(on: http)
        let zone = GraphFixture.farEast
        let patch = try CalendarToolHelpers.buildGCalEventInput([
            "start_iso": .string(spelling.spell(GraphFixture.wall(move.newStart, in: zone))),
            "end_iso": .string(spelling.spell(GraphFixture.wall(move.newStart.addingTimeInterval(1_800), in: zone))),
            "timezone": .string(zone),
        ], isAllDay: false)

        _ = try await makeProvider(http).updateEvent(eventId: "ser-z", event: patch)

        let after = try #require(graph.event("ser-z"))
        let start = try #require(after["start"] as? [String: Any])
        let storedDay = try #require(GraphFixture.deviceDay(wall: start["dateTime"] as? String ?? "",
                                                            in: start["timeZone"] as? String ?? ""))
        let seriesDay = GraphFixture.deviceDay(seriesStart)
        #expect((storedDay != seriesDay) == move.movesDate, "the series is stored on \(storedDay), was on \(seriesDay)")
        let wroteRecurrence = graph.patches("ser-z").contains { $0["recurrence"] != nil }
        if storedDay == seriesDay {
            #expect(!wroteRecurrence, "a move within the device's day wrote a recurrence")
            #expect(graph.seriesResets == 0, "a move within the device's day reset the series' exceptions")
        } else {
            #expect(wroteRecurrence, "a move to another day kept the range's old start date")
        }
        let range = (after["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        #expect(range?["startDate"] as? String == storedDay,
                "the range starts on \(range?["startDate"] as? String ?? "none"), the series on \(storedDay)")
    }

    @Test("an all-day series moved to another date moves its range's start date with it")
    func allDaySeriesMoved() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = FakeGraphCalendar([GraphFixture.event(id: "ser-ad", online: false, recurring: true, allDay: true)])
        graph.install(on: http)
        let before = try #require(graph.event("ser-ad"))
        let newDay = String(GraphFixture.naive(GraphFixture.start.addingTimeInterval(7 * 86_400)).prefix(10))
        let newEndDay = String(GraphFixture.naive(GraphFixture.start.addingTimeInterval(8 * 86_400)).prefix(10))
        var patch = GCalEventInput()
        patch.startDate = newDay

        _ = try await makeProvider(http).updateEvent(eventId: "ser-ad", event: patch)

        let after = try #require(graph.event("ser-ad"))
        let was = try #require(before["recurrence"] as? [String: Any])
        let now = try #require(after["recurrence"] as? [String: Any])
        #expect(canonical(now["pattern"]) == canonical(was["pattern"]), "the move changed the pattern")
        #expect((now["range"] as? [String: Any])?["startDate"] as? String == newDay)
        #expect(((after["start"] as? [String: Any])?["dateTime"] as? String)?.hasPrefix(newDay) == true, "the series did not move")
        #expect(((after["end"] as? [String: Any])?["dateTime"] as? String)?.hasPrefix(newEndDay) == true,
                "the end did not move with the start, is \((after["end"] as? [String: Any])?["dateTime"] as? String ?? "none")")
        #expect(after["isAllDay"] as? Bool == true, "the series stopped being all day")
    }

    /// "make it last two days": an all-day edit that gives only the end
    /// (`all_day` with `end_iso`) writes that end beside the start it had.
    /// (Whether an end-only edit should shift the start instead is #542.)
    @Test("an all-day event given only a new end keeps its start and ends on the new date")
    func allDayEndOnly() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = FakeGraphCalendar([GraphFixture.event(id: "ev-ad", online: false, allDay: true)])
        graph.install(on: http)
        let before = try #require(graph.event("ev-ad"))
        let day = String(GraphFixture.naive(GraphFixture.start).prefix(10))
        let newEndDay = String(GraphFixture.naive(GraphFixture.start.addingTimeInterval(2 * 86_400)).prefix(10))
        let patch = try CalendarToolHelpers.buildGCalEventInput(["end_iso": .string(newEndDay)], isAllDay: true)
        #expect(patch.endDate == newEndDay && patch.startDate == nil && patch.startDateTime == nil)

        _ = try await makeProvider(http).updateEvent(eventId: "ev-ad", event: patch)

        let after = try #require(graph.event("ev-ad"))
        #expect(((after["start"] as? [String: Any])?["dateTime"] as? String)?.hasPrefix(day) == true,
                "the start moved, is \((after["start"] as? [String: Any])?["dateTime"] as? String ?? "none")")
        #expect(((after["end"] as? [String: Any])?["dateTime"] as? String)?.hasPrefix(newEndDay) == true,
                "the new end was not written, is \((after["end"] as? [String: Any])?["dateTime"] as? String ?? "none")")
        #expect(after["isAllDay"] as? Bool == true, "the event stopped being all day")
        for property in watchedProperties where !["start", "end"].contains(property) {
            #expect(canonical(after[property]) == canonical(before[property]), "the end edit changed \(property)")
        }
    }

    @Test("a single event made recurring writes the rule at the date it starts on")
    func eventMadeRecurring() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let before = try #require(graph.event("ev-plain"))
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=WEEKLY;COUNT=3"]

        _ = try await makeProvider(http).updateEvent(eventId: "ev-plain", event: patch)

        let after = try #require(graph.event("ev-plain"))
        let recurrence = try #require(after["recurrence"] as? [String: Any])
        #expect((recurrence["pattern"] as? [String: Any])?["daysOfWeek"] as? [String] == [GraphFixture.weekday(GraphFixture.start)])
        let range = recurrence["range"] as? [String: Any]
        #expect(range?["startDate"] as? String == String(GraphFixture.naive(GraphFixture.start).prefix(10)))
        #expect((range?["numberOfOccurrences"] as? Int) == 3)
        expectOnlyEdited(nil, before: before.filter { $0.key != "recurrence" },
                         after: after.filter { $0.key != "recurrence" }, label: "event made recurring")
    }

    @Test("an edit of one occurrence leaves every property it did not edit as it was",
          arguments: UserCalendarEdit.ofAnOnlineMeeting)
    func oneOccurrence(_ edit: UserCalendarEdit) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let before = try #require(graph.event("ser-1-occ-2"))
        let masterBefore = try #require(graph.event("ser-1"))

        _ = try await makeProvider(http).updateOccurrence(
            eventId: "ser-1",
            recurrenceId: GraphFixture.naive(GraphFixture.occurrenceStart),
            recurrenceIdZone: GraphFixture.utc,
            event: edit.patch(start: GraphFixture.occurrenceStart)
        )

        let after = try #require(graph.event("ser-1-occ-2"))
        expectOnlyEdited(edit, before: before, after: after, start: GraphFixture.occurrenceStart, label: "occurrence")
        let masterAfter = try #require(graph.event("ser-1"))
        expectOnlyEdited(nil, before: masterBefore, after: masterAfter, label: "master of an occurrence edit")
    }

    @Test("an occurrence edit that gives a rule writes no recurrence and leaves the series as it was")
    func occurrenceIgnoresRule() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let master = try #require(graph.event("ser-1"))
        var patch = UserCalendarEdit.rename.patch(start: GraphFixture.occurrenceStart)
        patch.recurrence = ["RRULE:FREQ=DAILY"]

        _ = try await makeProvider(http).updateOccurrence(
            eventId: "ser-1", recurrenceId: GraphFixture.naive(GraphFixture.occurrenceStart),
            recurrenceIdZone: GraphFixture.utc, event: patch)

        let sent = graph.patches("ser-1-occ-2")
        #expect(sent.count == 1 && sent.allSatisfy { $0["recurrence"] == nil }, "the occurrence edit wrote a recurrence")
        #expect(graph.patches("ser-1").isEmpty, "the occurrence edit wrote the master")
        #expect(graph.event("ser-1-occ-2")?["subject"] as? String == "Planning (renamed)")
        expectOnlyEdited(nil, before: master, after: try #require(graph.event("ser-1")), label: "master")
    }

    @Test("an occurrence named by its own id is edited, and an empty occurrence edit writes nothing")
    func occurrenceByInstanceId() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let provider = makeProvider(http)
        let rid = GraphFixture.naive(GraphFixture.occurrenceStart)

        _ = try await provider.updateOccurrence(
            eventId: "ser-1-occ-2", recurrenceId: rid, recurrenceIdZone: GraphFixture.utc, event: GCalEventInput())
        #expect(http.recordedCalls().allSatisfy { $0.method == "GET" }, "an empty occurrence edit wrote")

        _ = try await provider.updateOccurrence(
            eventId: "ser-1-occ-2", recurrenceId: rid, recurrenceIdZone: GraphFixture.utc,
            event: UserCalendarEdit.markBusy.patch(start: GraphFixture.occurrenceStart))
        #expect(graph.patches("ser-1-occ-2").count == 1)
        #expect(graph.event("ser-1-occ-2")?["showAs"] as? String == "busy")
        #expect(graph.patches("ser-1").isEmpty)
    }

    @Test("an empty edit writes nothing")
    func emptyEditWritesNothing() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)

        _ = try await makeProvider(http).updateEvent(eventId: "ev-online", event: GCalEventInput())

        #expect(http.recordedCalls().allSatisfy { $0.method == "GET" })
    }

    @Test("an edit whose write is refused for an expired sign-in is written again with a fresh one")
    func patchRetriedAfter401() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        graph.failNext("PATCH", with: 401)

        _ = try await makeProvider(http).updateEvent(
            eventId: "ev-online", event: UserCalendarEdit.rename.patch(start: GraphFixture.start))

        #expect(http.recordedCalls().filter { $0.method == "PATCH" }.count == 2)
        #expect(graph.patchAuthorizations == ["Bearer stale-token", "Bearer fresh-token"],
                "the write was not retried with a refreshed sign-in: \(graph.patchAuthorizations)")
        #expect(graph.patches("ev-online").count == 1)
        #expect(graph.event("ev-online")?["subject"] as? String == "Planning (renamed)")
    }

    @Test("a recurrence written without its range's start date is refused by the fake as Graph refuses it")
    func fakeRefusesRangeWithoutStart() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let body = try JSONSerialization.data(withJSONObject: [
            "recurrence": ["pattern": ["type": "daily", "interval": 1], "range": ["type": "noEnd"]],
        ])
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/events/ser-1")!)
        request.httpMethod = "PATCH"
        request.httpBody = body
        let (_, response) = try await http.session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        #expect(graph.patches("ser-1").isEmpty)
    }

    @Test("an attendee whose address is stored in mixed case keeps its type when the attendees are written")
    func mixedCaseAttendeeKeepsItsType() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var event = GraphFixture.event(id: "ev-case", online: false)
        event["attendees"] = GraphFixture.attendees + [
            ["emailAddress": ["address": "Optional.Person@Example.com", "name": "Optional Person"], "type": "optional",
             "status": ["response": "none"]],
        ]
        let graph = FakeGraphCalendar([event])
        graph.install(on: http)
        var patch = UserCalendarEdit.addAttendee.patch(start: GraphFixture.start)
        patch.attendees?.append((email: "Optional.Person@Example.com", name: "Optional Person"))

        _ = try await makeProvider(http).updateEvent(eventId: "ev-case", event: patch)

        let after = try #require(graph.event("ev-case"))
        #expect(attendeeTypes(after)["optional.person@example.com"] == "optional",
                "the mixed-case attendee is \(attendeeTypes(after)["optional.person@example.com"] ?? "gone")")
        #expect(attendeeTypes(after)["bo@example.com"] == "optional")
    }

    // MARK: Online meetings (#511)

    @Test("in the fake, as measured live, a text body turns an online meeting off and an HTML body with only new notes keeps it")
    func fakeOnlineMeetingBodyWrites() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let before = try #require(graph.event("ev-online"))
        func patch(_ id: String, body: [String: Any]) async throws {
            var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/events/" + id)!)
            request.httpMethod = "PATCH"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["body": body])
            _ = try await http.session.data(for: request)
        }

        let notesOnly = GraphFixture.htmlHead + "<p>New notes</p>\r\n" + GraphFixture.joinSection + GraphFixture.htmlTail
        try await patch("ev-online", body: ["contentType": "html", "content": notesOnly])
        let kept = try #require(graph.event("ev-online"))
        #expect(kept["isOnlineMeeting"] as? Bool == true)
        #expect(kept["onlineMeetingProvider"] as? String == "teamsForBusiness")
        #expect(canonical(kept["onlineMeeting"]) == canonical(before["onlineMeeting"]))

        try await patch("ev-online", body: ["contentType": "text", "content": "New notes"])
        let after = try #require(graph.event("ev-online"))
        #expect(after["isOnlineMeeting"] as? Bool == false)
        #expect(after["onlineMeetingProvider"] as? String == "unknown")
        #expect(!(after["onlineMeeting"] is [String: Any]))
    }

    @Test("a read gives the stored notes in full as the description, an online meeting's without its join section, and its join link apart",
          arguments: ["ev-online", "ev-plain"])
    func readGivesTheNotes(_ id: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)

        let event = try await makeProvider(http).getEvent(eventId: id)

        let description = try #require(event.description)
        if id == "ev-online" {
            #expect(description.contains("[linked doc](https://example.com/doc)"), "the notes' link is \(description)")
            #expect(description.components(separatedBy: "Long notes past the preview.").count == 13,
                    "the notes past the 255-character preview were cut: \(description)")
            #expect(!description.contains("____") && !description.contains("Teams") && !description.contains("meet.example.com"),
                    "the join section is in the description: \(description)")
            #expect(event.conferenceUrl == GraphFixture.joinUrl)
        } else {
            #expect(description == "Agenda with bold notes and a [link](https://example.com/doc)")
            #expect(event.conferenceUrl == nil)
        }
    }

    @Test("a listing gives each event's stored notes in full as the description, an online meeting's without its join section, and its join link apart")
    func listGivesTheNotes() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)

        let listed = try await makeProvider(http).listEvents(
            timeMin: GraphFixture.start.addingTimeInterval(-86_400), timeMax: GraphFixture.occurrenceStart.addingTimeInterval(86_400))

        let online = try #require(listed.first { $0.id == "ev-online" })
        let description = try #require(online.description)
        #expect(description.components(separatedBy: "Long notes past the preview.").count == 13,
                "the listed notes were cut: \(description)")
        #expect(!description.contains("____") && !description.contains("Teams") && !description.contains("meet.example.com"),
                "the join section is in the listed description: \(description)")
        #expect(online.conferenceUrl == GraphFixture.joinUrl)
        let plain = try #require(listed.first { $0.id == "ev-plain" })
        #expect(plain.description == "Agenda with bold notes and a [link](https://example.com/doc)")
        #expect(plain.conferenceUrl == nil)
    }

    @Test("after the assistant puts the join link in an online meeting's notes, the next description edit still keeps the meeting on")
    func joinLinkWrittenIntoTheNotes() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let provider = makeProvider(http)
        let before = try #require(graph.event("ev-online"))
        let read = try await provider.getEvent(eventId: "ev-online")
        let link = try #require(read.conferenceUrl)
        var withLink = GCalEventInput()
        withLink.description = "Join here: " + link

        _ = try await provider.updateEvent(eventId: "ev-online", event: withLink)
        #expect(try #require(graph.event("ev-online"))["isOnlineMeeting"] as? Bool == true, "the first edit turned the meeting off")
        #expect(try await provider.getEvent(eventId: "ev-online").description == "Join here: " + link)
        var agenda = GCalEventInput()
        agenda.description = "Agenda only"
        _ = try await provider.updateEvent(eventId: "ev-online", event: agenda)

        expectNewNotes("Agenda only", before: before, after: try #require(graph.event("ev-online")),
                       label: "online meeting, edited after its notes held the join link")
    }

    @Test("an online meeting's description read, added to and written back keeps the notes in full and the meeting on")
    func onlineDescriptionRoundTrip() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let provider = makeProvider(http)
        let before = try #require(graph.event("ev-online"))
        let read = try #require(try await provider.getEvent(eventId: "ev-online").description)
        var patch = GCalEventInput()
        patch.description = read + "\nAdded line"

        _ = try await provider.updateEvent(eventId: "ev-online", event: patch)

        let after = try #require(graph.event("ev-online"))
        expectNewNotes(read + "\nAdded line", before: before, after: after, label: "online meeting, read and written back")
        for property in watchedProperties where property != "body" && property != "bodyPreview" {
            #expect(canonical(after[property]) == canonical(before[property]), "the round trip changed \(property)")
        }
        #expect(try await provider.getEvent(eventId: "ev-online").description == read + "\nAdded line")
    }

    @Test("clearing an online meeting's description keeps its join section")
    func clearedOnlineDescription() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let before = try #require(graph.event("ev-online"))
        var patch = GCalEventInput()
        patch.description = ""

        _ = try await makeProvider(http).updateEvent(eventId: "ev-online", event: patch)

        let after = try #require(graph.event("ev-online"))
        for property in watchedProperties where property != "body" && property != "bodyPreview" {
            #expect(canonical(after[property]) == canonical(before[property]), "clearing the notes changed \(property)")
        }
        let content = try #require((after["body"] as? [String: Any])?["content"] as? String)
        #expect(content == GraphFixture.htmlHead + "\r\n" + GraphFixture.joinSection + GraphFixture.htmlTail)
    }

    @Test("an online meeting whose join section is not recognised gets the description as text, as any event does")
    func unrecognisedJoinSection() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var event = GraphFixture.event(id: "ev-unknown-layout")
        // The join link with no separator line before it.
        event["body"] = ["contentType": "html", "content": GraphFixture.htmlHead + "<div>Notes</div><div><a href=\""
            + GraphFixture.joinUrl.replacingOccurrences(of: "&", with: "&amp;") + "\">Join</a></div>" + GraphFixture.htmlTail]
        let graph = FakeGraphCalendar([event])
        graph.install(on: http)

        _ = try await makeProvider(http).updateEvent(
            eventId: "ev-unknown-layout", event: UserCalendarEdit.newDescription.patch(start: GraphFixture.start))

        let sent = try #require(graph.patches("ev-unknown-layout").first?["body"] as? [String: Any])
        #expect(sent["contentType"] as? String == "text")
        #expect(sent["content"] as? String == UserCalendarEdit.newDescriptionText)
    }
}
