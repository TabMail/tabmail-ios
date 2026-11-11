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
///   a range written without `recurrenceTimeZone` came back labelled UTC (see
///   `defaultRecurrenceZone`), and a rule
///   that differs from the stored one makes Graph restore deleted occurrences
///   and move moved ones back — counted in `seriesResets`. Writing the stored
///   recurrence back exactly changed nothing. A recurrence that differs only in
///   its pattern's `firstDayOfWeek` is assumed to reset the same way (not
///   measured), so it is counted too;
/// - writing a series' `start` or `end` (measured on a work account on
///   2026-11-10): a PATCH of start and end alone, with no recurrence and the
///   stored recurrence left as it was, brought a deleted occurrence back and
///   made a moved one a plain occurrence at the new time — also counted in
///   `seriesResets`. Counted when the written start or end differs from the
///   stored one (wall time and zone label), or an `isAllDay` that differs (a
///   series made all-day or timed, assumed to reset as a moved start does);
///   writing them back unchanged was not measured;
/// - a `recurrence` written without `start` moves the series' start and end to
///   UTC midnight on the range's `startDate` (measured, see `splitSeries`);
/// - a recurrence whose range has no `startDate` is refused with a 400
///   (`recurrenceRange`: "Required");
/// - `$select` returns only the properties it names (`event-get`);
/// - a series' instances list (`/events/{id}/instances`) holds the occurrences stored with its
///   `seriesMasterId` that START, where they are now, inside the window the request names; of a
///   series whose range ends on a date (`type` `endDate`), only those whose place in the series
///   (`originalStart`) is on or before that date in the range's `recurrenceTimeZone`: Graph lists
///   none after a series' end (measured: a series capped by a split no longer listed the
///   occurrences from the split on);
/// - an occurrence moved onto the time another occurrence of its series starts at is refused with
///   a 400 (`ErrorOccurrenceCrossingBoundary`), and nothing changes;
/// - `calendarView` lists single events and occurrences, never a series master
///   (`user-list-calendarview`); this fake lists every stored one, whatever the
///   window, in no particular order;
/// - a body written without an online meeting's join link turns the online
///   meeting off: "Inadvertently removing the meeting blob from the body would
///   disable meeting online" (event-update). Checked live on a work account: a
///   text body write left `isOnlineMeeting` false, `onlineMeetingProvider`
///   `unknown` and `onlineMeeting` null; an HTML write that changed only the
///   notes kept the meeting and its join link;
/// - a create (`POST /me/events`) stores the event it is sent under a new id,
///   with the same recurrence rules as a PATCH;
/// - a PATCH whose `attendees` holds any entry without a `status` is refused
///   with 405 `UnknownError` and an empty message, and changes nothing.
///   Measured on an Outlook.com account (#622): a list with every entry
///   carrying its status was accepted, and a kept attendee sent with their
///   stored status kept their answer.
///
/// Starts and ends are returned as stored, whatever zone `Prefer` names: a
/// fixture stores them as Graph renders them for the device. An occurrence's
/// `originalStart` (stored as any ISO 8601 date-time) is returned as Graph returns
/// it (measured 2026-11-11 on all-day series in Pacific Standard Time, Tokyo
/// Standard Time and Asia/Kathmandu): written in the zone `Prefer:
/// outlook.timezone` names, with that zone's offset (`…T00:00:00+09:00`), and as
/// a UTC instant (`…Z`) when the request names none. The zone is the one Graph
/// knows by that name: `zones`, else `CalendarTimeZoneResolver`.
final class FakeGraphCalendar: Sendable {
    private let events: Mutex<[String: Data]>
    private let resets = Mutex(0)
    private let patchLog = Mutex<[(id: String, body: Data)]>([])
    private let patchAuthorizationLog = Mutex<[String]>([])
    private let failingRequests = Mutex<[String: [Int]]>([:])
    private let lostResponses = Mutex<[String: Int]>([:])
    private let readLog = Mutex<[(id: String, zone: String?)]>([])

    /// Zones the server knows by a name TabMail may not (`Prefer` reads them).
    private let zones: [String: TimeZone]

    init(_ seed: [[String: Any]], zones: [String: TimeZone] = [:]) {
        var map: [String: Data] = [:]
        for event in seed {
            // swiftlint:disable:next force_try
            map[event["id"] as! String] = try! JSONSerialization.data(withJSONObject: event)
        }
        events = Mutex(map)
        self.zones = zones
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

    /// The next `method` write is applied, and its response is lost: the connection drops before
    /// it arrives (`PATCH` and `POST`).
    func loseNextResponse(_ method: String) { lostResponses.withLock { $0[method, default: 0] += 1 } }

    private func takeLoss(_ method: String) -> Bool {
        lostResponses.withLock { lost in
            guard let count = lost[method], count > 0 else { return false }
            lost[method] = count - 1
            return true
        }
    }

    /// The zone `Prefer: outlook.timezone` named on each read of `id` by its own id (nil: none),
    /// in order.
    func readZones(_ id: String) -> [String?] { readLog.withLock { $0 }.filter { $0.id == id }.map(\.zone) }

    /// The PATCH bodies sent for `id`, in order.
    func patches(_ id: String) -> [[String: Any]] {
        patchLog.withLock { $0 }.filter { $0.id == id }
            .compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] }
    }

    /// The `Authorization` header of every PATCH, refused ones included, in order.
    var patchAuthorizations: [String] { patchAuthorizationLog.withLock { $0 } }

    /// The events a create stored, as stored.
    var created: [[String: Any]] {
        ids.filter { $0.hasPrefix(Self.createdPrefix) }.sorted().compactMap(event)
    }

    private static let createdPrefix = "created-"

    func install(on http: FakeHTTP.Scenario) {
        http.register(path: "/v1.0/me/events/", method: "GET") { [self] request in
            if let status = takeFailure("GET") { return .status(status) }
            let parts = Self.pathParts(request.url)
            let select = Self.selected(request.url)
            let preferName = Self.preferredZoneName(request)
            let prefer = preferName.flatMap { zones[$0] ?? CalendarTimeZoneResolver.zone(named: $0, in: .none) }
            if parts.count == 2, parts[1] == "instances" {
                let window = Self.window(request.url)
                let master = event(parts[0])
                let instances = events.withLock { Array($0.values) }
                    .compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                    .filter { $0["seriesMasterId"] as? String == parts[0] }
                    .filter { Self.starts($0, in: window) }
                    .filter { Self.isInSeries($0, master: master) }
                return Self.json(["value": instances.map { Self.only(select, of: Self.rendered($0, in: prefer)) }])
            }
            if parts.count == 1 { readLog.withLock { $0.append((id: parts[0], zone: preferName)) } }
            guard parts.count == 1, let stored = event(parts[0]) else { return .status(404) }
            return Self.json(Self.only(select, of: Self.rendered(stored, in: prefer)))
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
            if let attendees = patch["attendees"] as? [[String: Any]], attendees.contains(where: { $0["status"] == nil }) {
                return .json(raw: #"{"error":{"code":"UnknownError","message":""}}"#, statusCode: 405)
            }
            if let master = stored["seriesMasterId"] as? String, let start = patch["start"],
               let at = Self.instant(start), occurrence(of: master, other: parts[0], startsAt: at) {
                return .json(raw: #"{"error":{"code":"ErrorOccurrenceCrossingBoundary","message":"An occurrence can't be moved onto another occurrence of its series."}}"#,
                             statusCode: 400)
            }
            patchLog.withLock { $0.append((id: parts[0], body: body)) }
            let changesRule = patch["recurrence"].map { Self.canonicalJSON($0) != Self.canonicalJSON(stored["recurrence"]) } ?? false
            let isSeries = stored["recurrence"] != nil && !(stored["recurrence"] is NSNull)
            let movesTime = isSeries && (["start", "end"].contains { key in
                patch[key].map { !Self.sameTime($0, stored[key]) } ?? false
            } || patch["isAllDay"].map { ($0 as? Bool) != (stored["isAllDay"] as? Bool) } ?? false)
            if changesRule || movesTime {
                resets.withLock { $0 += 1 }
            }
            Self.apply(patch, to: &stored)
            store(stored)
            if takeLoss("PATCH") { return .transportError(.networkConnectionLost) }
            return Self.json(stored)
        }
        http.register(path: "/v1.0/me/events", method: "POST") { [self] request in
            if let status = takeFailure("POST") { return .status(status) }
            guard let body = request.body,
                  var created = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  Self.rangeHasStart(created)
            else { return .status(400) }
            created["id"] = Self.createdPrefix + String(ids.filter { $0.hasPrefix(Self.createdPrefix) }.count + 1)
            Self.defaultRecurrenceZone(in: &created)
            store(created)
            if takeLoss("POST") { return .transportError(.networkConnectionLost) }
            return Self.json(created)
        }
    }

    /// The instances window a request names (`startDateTime`, `endDateTime`: naive UTC wall times),
    /// nil when it names none.
    private static func window(_ url: URL) -> (from: Date, to: Date)? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> Date? {
            items.first { $0.name == name }?.value.flatMap { EKEventStoreHelper.parseNaiveISO(String($0.prefix(19)), timeZone: .gmt) }
        }
        guard let from = value("startDateTime"), let to = value("endDateTime") else { return nil }
        return (from, to)
    }

    /// Whether `event` starts NOW (where it is, not its place in the series) inside `window`, as
    /// Graph's instances list filters; every event when there is no window.
    private static func starts(_ event: [String: Any], in window: (from: Date, to: Date)?) -> Bool {
        guard let window else { return true }
        guard let at = instant(event["start"]) else { return false }
        return at >= window.from && at < window.to
    }

    /// The zone name a request's `Prefer: outlook.timezone="…"` gives; nil when it gives none.
    private static func preferredZoneName(_ request: FakeHTTP.Request) -> String? {
        guard let prefer = request.header("Prefer"), let open = prefer.range(of: "outlook.timezone=\"") else { return nil }
        return String(prefer[open.upperBound...].prefix { $0 != "\"" })
    }

    /// `event` as a read in `zone` returns it: its `originalStart` written with `zone`'s offset, or
    /// in UTC when the read names no zone.
    private static func rendered(_ event: [String: Any], in zone: TimeZone?) -> [String: Any] {
        guard let stored = event["originalStart"] as? String, let instant = Date.fromISO8601(stored) else { return event }
        var out = event
        out["originalStart"] = instant.iso8601String(timeZone: zone ?? .gmt)
        return out
    }

    /// Whether `occurrence`'s place in the series (`originalStart`, else its start) is on or before
    /// the end of `master`'s range when it ends on a date, that date read in the range's zone.
    private static func isInSeries(_ occurrence: [String: Any], master: [String: Any]?) -> Bool {
        guard let range = (master?["recurrence"] as? [String: Any])?["range"] as? [String: Any],
              range["type"] as? String == "endDate", let end = range["endDate"] as? String,
              let zoneName = range["recurrenceTimeZone"] as? String,
              let zone = CalendarTimeZoneResolver.zone(named: zoneName, in: .none),
              let place = (occurrence["originalStart"] as? String).flatMap({ Date.fromISO8601($0) }) ?? instant(occurrence["start"])
        else { return true }
        return EKEventStoreHelper.dayKey(place, timeZone: zone) <= end
    }

    /// The instant a stored or written start names: its wall time read in the zone it is labelled
    /// with (an all-day one at that date's midnight there).
    private static func instant(_ value: Any?) -> Date? {
        guard let value = value as? [String: Any], let dateTime = value["dateTime"] as? String,
              let zone = CalendarTimeZoneResolver.zone(named: value["timeZone"] as? String ?? "UTC", in: .none) else { return nil }
        return EKEventStoreHelper.parseNaiveISO(String(dateTime.prefix(19)), timeZone: zone)
    }

    /// Whether an occurrence of `master` other than `other` starts at `at` now: Graph refuses a move
    /// of an occurrence onto another one of its series.
    private func occurrence(of master: String, other: String, startsAt at: Date) -> Bool {
        events.withLock { Array($0.values) }
            .compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            .contains { $0["seriesMasterId"] as? String == master && $0["id"] as? String != other && Self.instant($0["start"]) == at }
    }

    /// Whether a written start or end names the stored one: the same wall time to the
    /// second and the same zone label.
    private static func sameTime(_ written: Any, _ stored: Any?) -> Bool {
        guard let written = written as? [String: Any], let stored = stored as? [String: Any] else { return false }
        func wall(_ value: [String: Any]) -> String { String((value["dateTime"] as? String ?? "").prefix(19)) }
        return wall(written) == wall(stored) && written["timeZone"] as? String == stored["timeZone"] as? String
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

    /// A recurrence written without `recurrenceTimeZone` is stored labelled UTC, as
    /// measured on a series that the same write moved to UTC. Graph's documented
    /// default is the event's own zone (`recurrenceRange`), which is the zone the
    /// app dates `endDate` in. This fake models the measured label, and nothing
    /// here reads a range's dates in it.
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
    /// Where Graph places an all-day occurrence of a series repeating in `zone` on `date`
    /// (`originalStart`): the instant the date begins there, in UTC.
    static func allDayPlace(_ date: String, in zone: String = "America/Los_Angeles") -> String {
        guard let tz = TimeZone(identifier: zone),
              let midnight = EKEventStoreHelper.parseNaiveISO(date, timeZone: tz) else { return date + "T00:00:00Z" }
        return midnight.iso8601String(timeZone: .gmt)
    }
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

    /// The instant a stored Graph `start` or `end` names: its wall time read in its label.
    static func instant(_ side: [String: Any]?) -> Date? {
        guard let wall = side?["dateTime"] as? String, let zone = side?["timeZone"] as? String,
              let tz = TimeZone(identifier: zone) else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = tz
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fmt.date(from: String(wall.prefix(19)))
    }

    static func weekday(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        return names[cal.component(.weekday, from: date) - 1]
    }

    /// When the fixture's guests answered: a day before the test runs.
    static let answeredAt = rfc3339(Date().addingTimeInterval(-86_400))

    static var attendees: [[String: Any]] { [
        ["emailAddress": ["address": "ana@example.com", "name": "Ana"], "type": "required",
         "status": ["response": "accepted", "time": answeredAt]],
        ["emailAddress": ["address": "bo@example.com", "name": "Bo"], "type": "optional",
         "status": ["response": "tentativelyAccepted", "time": answeredAt]],
        ["emailAddress": ["address": "room-1@example.com", "name": "Room 1"], "type": "resource",
         "status": ["response": "accepted", "time": answeredAt]],
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
        if let seriesMasterId {
            e["seriesMasterId"] = seriesMasterId
            // An occurrence's place in its series, as Graph gives it (measured): an instant in UTC,
            // with no zone named; an all-day occurrence's is the instant its date begins in the
            // series' zone (the range's `recurrenceTimeZone` above, Pacific).
            e["originalStart"] = allDay ? allDayPlace(utcDay(start)) : rfc3339(start)
        }
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

/// How the assistant may spell a start or end it hands the calendar tools: the
/// asked-for wall time without an offset (with or without seconds), read in the
/// edit's zone, or a time with a UTC offset or `Z`, which names the instant it
/// spells (as Google Calendar reads it) whatever zone the edit is labelled with.
enum StartSpelling: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case z = "Z", fractionZ = ".000Z", plusZero = "+00:00", noSecondsZ = "HH:mmZ"
    case plusFourteen = "+14:00", noSecondsPlusFourteen = "HH:mm+14:00"
    case naive = "HH:mm:ss", noSeconds = "HH:mm"

    var testDescription: String { rawValue }

    /// `instant` spelled this way, for an edit labelled with `zone`.
    func spell(_ instant: Date, label zone: String) -> String {
        let utc = GraphFixture.naive(instant)
        let farEast = GraphFixture.wall(instant, in: GraphFixture.farEast)
        let wall = GraphFixture.wall(instant, in: zone)
        switch self {
        case .z, .fractionZ, .plusZero: return utc + rawValue
        case .noSecondsZ: return String(utc.prefix(16)) + "Z"
        case .plusFourteen: return farEast + "+14:00"
        case .noSecondsPlusFourteen: return String(farEast.prefix(16)) + "+14:00"
        case .naive: return wall
        case .noSeconds: return String(wall.prefix(16))
        }
    }
}

/// An all-day date the assistant spells with a time and an offset whose instant falls on
/// another calendar day in the edit's zone (`label`), on either side of midnight. An all-day
/// value is a plain date with no zone, so the date is the one spelled.
enum AllDaySpelling: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// Midnight UTC is the evening before in Los Angeles.
    case eastOfLabel = "T00:00:00Z"
    /// 23:30 at UTC-10 is the next morning in Los Angeles.
    case westOfLabel = "T23:30:00-10:00"

    var testDescription: String { rawValue }
    static let label = "America/Los_Angeles"
    static let day = "2099-05-20"
    static let nextDay = "2099-05-21"

    func spell(_ day: String) -> String { day + rawValue }
}

/// A series' recurrence as Graph stores it (every field, the unused ones at their
/// defaults, in a zone other than UTC and with weeks starting on Monday), one of
/// each range kind.
enum StoredRule: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case weeklyNoEnd, relativeMonthlyEndDate, absoluteYearlyNumbered, everyOtherDayNumbered

    var testDescription: String { rawValue }

    func recurrence(start: Date) -> [String: Any] {
        let startDate = GraphFixture.utcDay(start)
        let pattern: [String: Any]
        let range: [String: Any]
        switch self {
        case .weeklyNoEnd:
            pattern = ["type": "weekly", "interval": 1, "month": 0, "dayOfMonth": 0,
                       "daysOfWeek": [GraphFixture.weekday(start)], "firstDayOfWeek": "monday", "index": "first"]
            range = ["type": "noEnd", "startDate": startDate, "endDate": "0001-01-01", "numberOfOccurrences": 0]
        case .relativeMonthlyEndDate:
            pattern = ["type": "relativeMonthly", "interval": 1, "month": 0, "dayOfMonth": 0,
                       "daysOfWeek": ["tuesday", "thursday"], "firstDayOfWeek": "monday", "index": "second"]
            range = ["type": "endDate", "startDate": startDate,
                     "endDate": GraphFixture.utcDay(start.addingTimeInterval(90 * 86_400)), "numberOfOccurrences": 0]
        case .absoluteYearlyNumbered:
            pattern = ["type": "absoluteYearly", "interval": 1, "month": 3, "dayOfMonth": 15,
                       "daysOfWeek": [String](), "firstDayOfWeek": "monday", "index": "first"]
            range = ["type": "numbered", "startDate": startDate, "endDate": "0001-01-01", "numberOfOccurrences": 4]
        case .everyOtherDayNumbered:
            pattern = ["type": "daily", "interval": 2, "month": 0, "dayOfMonth": 0,
                       "daysOfWeek": [String](), "firstDayOfWeek": "monday", "index": "first"]
            range = ["type": "numbered", "startDate": startDate, "endDate": "0001-01-01", "numberOfOccurrences": 6]
        }
        var zoned = range
        zoned["recurrenceTimeZone"] = "Pacific Standard Time"
        return ["pattern": pattern, "range": zoned]
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
    attendeeEntries(event).mapValues { $0["type"] as? String ?? "?" }
}

/// email (lowercased) → the whole attendee entry: type, status (answer and its time) and name.
private func attendeeEntries(_ event: [String: Any]) -> [String: [String: Any]] {
    var out: [String: [String: Any]] = [:]
    for attendee in event["attendees"] as? [[String: Any]] ?? [] {
        guard let email = (attendee["emailAddress"] as? [String: Any])?["address"] as? String else { continue }
        out[email.lowercased()] = attendee
    }
    return out
}

/// Asserts a description edit wrote `notes`: as the HTML body of an event that is
/// no online meeting; for an online meeting, in place of the stored notes, with
/// the join section and everything after it as stored, and the meeting on.
private func expectNewNotes(_ notes: String, before: [String: Any], after: [String: Any], label: String) {
    let body = after["body"] as? [String: Any]
    guard before["onlineMeeting"] is [String: Any] else {
        #expect(body?["contentType"] as? String == "html", "\(label): the description was not written as HTML")
        #expect(body?["content"] as? String == notes.replacingOccurrences(of: "\n", with: "<br>\r\n"),
                "\(label): the description written is \(body?["content"] ?? "none")")
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
/// edited event's start). For an attendee edit, every attendee that stays is
/// written exactly as stored (type, answer and its time, name), the one removed
/// is gone, and the one added is `required` and unanswered.
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
        let wasEntries = attendeeEntries(before)
        let nowEntries = attendeeEntries(after)
        let removed = edit == .removeAttendee ? UserCalendarEdit.removedAttendee : nil
        for (email, type) in was where email != removed {
            #expect(now[email] == type, "\(label): attendee \(email) was \(type), is \(now[email] ?? "gone")")
            #expect(canonical(nowEntries[email]) == canonical(wasEntries[email]),
                    "\(label): attendee \(email) was \(canonical(wasEntries[email])), is \(canonical(nowEntries[email]))")
        }
        if let removed {
            #expect(was[removed] != nil && now[removed] == nil, "\(label): the removed attendee is \(now[removed] ?? "gone")")
            #expect(now.count == was.count - 1, "\(label): \(now.count) attendees after removing one of \(was.count)")
        } else {
            #expect(now["cy@example.com"] == "required", "\(label): the added attendee is \(now["cy@example.com"] ?? "missing")")
            let added = nowEntries["cy@example.com"]?["status"] as? [String: Any]
            #expect(added?["response"] as? String == "none", "\(label): the added attendee's status is \(canonical(added))")
            // The form measured accepted, spelled out: comparing with the provider's own
            // constant would pass whatever that constant held.
            #expect(canonical(added) == canonical(["response": "none", "time": "0001-01-01T00:00:00Z"]),
                    "\(label): the added attendee's status is \(canonical(added))")
            let address = nowEntries["cy@example.com"]?["emailAddress"] as? [String: Any]
            #expect(address?["name"] as? String == "Cy", "\(label): the added attendee's name is \(canonical(address))")
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

    @Test("a description edit writes the notes and nothing else")
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
        #expect(body["contentType"] as? String == "html")
        #expect(body["content"] as? String == "New notes<br>\r\nSecond line")
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
    /// no `recurrence` at all. A time change still resets them: Graph does that
    /// for any change of a series' start or end (measured, 2026-11-10), which
    /// the edit's card says (`editResetsChangedOccurrences`).
    @Test("an edit of a whole series that gives no rule writes no recurrence, and resets only on a time change",
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
        let movesTime = edit == .moveOneHour || edit == .endLater
        #expect(graph.seriesResets == (movesTime ? 1 : 0),
                "\(edit.rawValue): \(graph.seriesResets) resets of the series' exceptions; Graph resets them on a time change only")
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

    /// #423, measured: a rule written without the series' zone is stored as UTC (a
    /// series pinned to UTC moves by an hour in local time across a daylight saving
    /// change), and one naming Sunday moves the series' weeks to start on Sunday.
    /// "make it every other week": the new rule is written in the series' own zone,
    /// with its own first day of the week.
    @Test("a rule change on a series keeps the series' zone and first day of the week")
    func ruleChangeKeepsZoneAndFirstDay() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let before = try #require(graph.event("ser-1"))
        let wasRecurrence = try #require(before["recurrence"] as? [String: Any])
        let wasZone = (wasRecurrence["range"] as? [String: Any])?["recurrenceTimeZone"] as? String
        let wasFirstDay = (wasRecurrence["pattern"] as? [String: Any])?["firstDayOfWeek"] as? String
        #expect(wasZone == "Pacific Standard Time" && wasFirstDay == "monday", "the fixture's series is not the measured one")
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=WEEKLY;INTERVAL=2"]

        _ = try await makeProvider(http).updateEvent(eventId: "ser-1", event: patch)

        let after = try #require(graph.event("ser-1"))
        let recurrence = try #require(after["recurrence"] as? [String: Any])
        let pattern = recurrence["pattern"] as? [String: Any]
        let range = recurrence["range"] as? [String: Any]
        #expect(pattern?["interval"] as? Int == 2, "the new rule was not written")
        #expect(range?["recurrenceTimeZone"] as? String == wasZone,
                "the series' zone is \(range?["recurrenceTimeZone"] as? String ?? "none"), was \(wasZone ?? "none")")
        #expect(pattern?["firstDayOfWeek"] as? String == wasFirstDay,
                "the series' weeks start on \(pattern?["firstDayOfWeek"] as? String ?? "none"), did on \(wasFirstDay ?? "none")")
        for property in watchedProperties where property != "recurrence" {
            #expect(canonical(after[property]) == canonical(before[property]), "the rule change changed \(property)")
        }
    }

    /// The series' own rule re-sent with a first day of the week of its own (`WKST`) is a rule
    /// change: written with that day, and the card warns of the reset (assumed, not measured,
    /// for a change of only the first day).
    @Test("a whole-series edit that changes only the rule's first day of the week is written and warned of")
    func firstDayOnlyEditIsWrittenAndWarned() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let provider = makeProvider(http)
        let read = try await provider.getEvent(eventId: "ser-1")
        let rule = try #require(read.recurrence?.first)
        #expect(!rule.contains("WKST"), "the read rule is \(rule)")
        var patch = GCalEventInput()
        patch.recurrence = [rule + ";WKST=SU"]

        let answer = provider.editResetsChangedOccurrences(read, edit: patch)
        _ = try await provider.updateEvent(eventId: "ser-1", event: patch)

        let sent = graph.patches("ser-1")
        #expect(sent.count == 1, "\(sent.count) PATCHes")
        let pattern = (sent.first?["recurrence"] as? [String: Any])?["pattern"] as? [String: Any]
        #expect(pattern?["firstDayOfWeek"] as? String == "sunday",
                "the PATCH's weeks start on \(pattern?["firstDayOfWeek"] as? String ?? "none")")
        #expect(answer, "the card does not warn of a reset for the first-day change")
        #expect(graph.seriesResets == 1, "\(graph.seriesResets) resets of the series' exceptions")
    }

    /// A rule change that names its own first day of the week is written with that day, not
    /// the series' stored one.
    @Test("a rule change with its own first day of the week is written with that day")
    func ruleChangeWithFirstDayWritesIt() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let provider = makeProvider(http)
        let read = try await provider.getEvent(eventId: "ser-1")
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=WEEKLY;INTERVAL=2;WKST=SU"]

        let answer = provider.editResetsChangedOccurrences(read, edit: patch)
        _ = try await provider.updateEvent(eventId: "ser-1", event: patch)

        let after = try #require(graph.event("ser-1"))
        let recurrence = try #require(after["recurrence"] as? [String: Any])
        let pattern = recurrence["pattern"] as? [String: Any]
        #expect(pattern?["interval"] as? Int == 2, "the new rule was not written")
        #expect(pattern?["firstDayOfWeek"] as? String == "sunday",
                "the series' weeks start on \(pattern?["firstDayOfWeek"] as? String ?? "none")")
        #expect((recurrence["range"] as? [String: Any])?["recurrenceTimeZone"] as? String == "Pacific Standard Time")
        #expect(answer, "the card does not warn of a reset for the rule change")
    }

    /// The series' own rule re-sent with no first day of the week keeps the stored one: nothing
    /// is sent, the card does not warn, and the series' weeks still start on its stored day.
    @Test("a re-sent rule with no first day of the week keeps the stored one and sends nothing")
    func resentRuleWithoutFirstDayKeepsStored() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let provider = makeProvider(http)
        let read = try await provider.getEvent(eventId: "ser-1")
        #expect(read.recurrenceFirstDayOfWeek == "monday", "the read first day is \(read.recurrenceFirstDayOfWeek ?? "none")")
        var patch = GCalEventInput()
        patch.recurrence = [try #require(read.recurrence?.first)]

        let answer = provider.editResetsChangedOccurrences(read, edit: patch)
        _ = try await provider.updateEvent(eventId: "ser-1", event: patch)

        #expect(graph.patches("ser-1").isEmpty, "\(graph.patches("ser-1").count) PATCHes")
        #expect(!answer, "the card warns of a reset for the series' own rule")
        #expect(graph.seriesResets == 0)
        let pattern = (try #require(graph.event("ser-1"))["recurrence"] as? [String: Any])?["pattern"] as? [String: Any]
        #expect(pattern?["firstDayOfWeek"] as? String == "monday")
    }

    /// #423, measured: writing a series' stored recurrence back exactly changed
    /// nothing, but writing it rebuilt from its RRULE restored deleted occurrences
    /// and moved moved ones back. The assistant re-sends the rule it read with an
    /// edit, so a whole-series edit whose rule is the series' own resets nothing,
    /// whatever kind of rule and range the series has.
    @Test("a whole-series edit that re-sends the series' own rule resets nothing and leaves the series as it was",
          arguments: StoredRule.allCases, [false, true])
    func resentRuleResetsNothing(_ rule: StoredRule, _ withRename: Bool) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var series = GraphFixture.event(id: "ser-r", online: false, recurring: true)
        series["recurrence"] = rule.recurrence(start: GraphFixture.start)
        let graph = FakeGraphCalendar([series])
        graph.install(on: http)
        let before = try #require(graph.event("ser-r"))
        let provider = makeProvider(http)
        var patch = withRename ? UserCalendarEdit.rename.patch(start: GraphFixture.start) : GCalEventInput()
        let read = try await provider.getEvent(eventId: "ser-r")
        patch.recurrence = [try #require(read.recurrence?.first)]

        _ = try await provider.updateEvent(eventId: "ser-r", event: patch)

        let label = "\(rule.rawValue)\(withRename ? " with a rename" : "")"
        let sent = graph.patches("ser-r")
        #expect(sent.count == (withRename ? 1 : 0), "\(label): \(sent.count) PATCHes")
        #expect(sent.allSatisfy { $0["recurrence"] == nil }, "\(label): the PATCH carried a recurrence")
        #expect(graph.seriesResets == 0, "\(label): the edit reset the series' exceptions")
        let after = try #require(graph.event("ser-r"))
        expectOnlyEdited(withRename ? .rename : nil, before: before, after: after, label: label)
    }

    /// The series' own rule with its days named in another order is the same rule.
    @Test("a whole-series edit that re-sends the series' own rule with its days in another order resets nothing")
    func resentRuleInAnotherDayOrder() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var series = GraphFixture.event(id: "ser-d", online: false, recurring: true)
        series["recurrence"] = StoredRule.relativeMonthlyEndDate.recurrence(start: GraphFixture.start)
        let graph = FakeGraphCalendar([series])
        graph.install(on: http)
        let before = try #require(graph.event("ser-d"))
        let provider = makeProvider(http)
        let read = try #require(try await provider.getEvent(eventId: "ser-d").recurrence?.first)
        #expect(read.contains("BYDAY=TU,TH"), "the read rule is \(read)")
        var patch = UserCalendarEdit.rename.patch(start: GraphFixture.start)
        patch.recurrence = [read.replacingOccurrences(of: "BYDAY=TU,TH", with: "BYDAY=TH,TU")]

        _ = try await provider.updateEvent(eventId: "ser-d", event: patch)

        #expect(graph.patches("ser-d").allSatisfy { $0["recurrence"] == nil }, "the PATCH carried a recurrence")
        #expect(graph.seriesResets == 0, "the edit reset the series' exceptions")
        let after = try #require(graph.event("ser-d"))
        expectOnlyEdited(.rename, before: before, after: after, label: "days in another order")
    }

    /// The same, with the series moved a week later: the rule is the series' own,
    /// so the stored recurrence is written with only its range's start date moved.
    @Test("a whole series moved to another date with its own rule re-sent keeps its recurrence but for the range's start date")
    func resentRuleWithDateMove() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let before = try #require(graph.event("ser-1"))
        let provider = makeProvider(http)
        let newStart = GraphFixture.start.addingTimeInterval(7 * 86_400)
        var patch = GCalEventInput()
        patch.startDateTime = GraphFixture.rfc3339(newStart)
        patch.startTimeZone = "UTC"
        let read = try await provider.getEvent(eventId: "ser-1")
        patch.recurrence = [try #require(read.recurrence?.first)]

        _ = try await provider.updateEvent(eventId: "ser-1", event: patch)

        let after = try #require(graph.event("ser-1"))
        let was = try #require(before["recurrence"] as? [String: Any])
        let now = try #require(after["recurrence"] as? [String: Any])
        #expect(canonical(now["pattern"]) == canonical(was["pattern"]), "the move changed the pattern")
        var range = try #require(now["range"] as? [String: Any])
        #expect(range["startDate"] as? String == GraphFixture.utcDay(newStart), "the range's start date did not move")
        range["startDate"] = (was["range"] as? [String: Any])?["startDate"]
        #expect(canonical(range) == canonical(was["range"]), "the move changed the range beyond its start date")
    }

    /// A series kept in Tokyo's zone (stored by its Windows name) whose start Graph
    /// gives in UTC at 20:00, which is 05:00 the next day in Tokyo. "repeat daily
    /// until …" ends at 21:00 UTC ten days later, 06:00 eleven days later in Tokyo:
    /// the series' last day in its own zone is the eleventh, which is the date the
    /// range's end must name, since Graph reads it in that zone.
    @Test("a rule change dates its end in the series' stored zone, not the start's")
    func ruleChangeEndsInTheStoredZone() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = GraphFixture.utc
        let day = cal.startOfDay(for: Date().addingTimeInterval(30 * 86_400))
        let start = day.addingTimeInterval(20 * 3_600)
        var series = GraphFixture.event(id: "ser-tk", start: start, online: false, recurring: true)
        var recurrence = try #require(series["recurrence"] as? [String: Any])
        var range = try #require(recurrence["range"] as? [String: Any])
        range["recurrenceTimeZone"] = "Tokyo Standard Time"
        recurrence["range"] = range
        series["recurrence"] = recurrence
        let graph = FakeGraphCalendar([series])
        graph.install(on: http)
        let until = day.addingTimeInterval(10 * 86_400 + 21 * 3_600)
        let untilText = GraphFixture.naive(until).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "") + "Z"
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=DAILY;UNTIL=\(untilText)"]

        _ = try await makeProvider(http).updateEvent(eventId: "ser-tk", event: patch)

        let written = (graph.event("ser-tk")?["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        let tokyoLastDay = GraphFixture.utcDay(day.addingTimeInterval(11 * 86_400))
        #expect(written?["type"] as? String == "endDate", "the new rule's end was not written")
        #expect(written?["endDate"] as? String == tokyoLastDay,
                "the series ends on \(written?["endDate"] as? String ?? "none"), its last day in Tokyo is \(tokyoLastDay)")
        #expect(written?["recurrenceTimeZone"] as? String == "Tokyo Standard Time")
        // Graph reads the range's start date in the same zone and requires it to match the
        // start: 20:00 UTC is the next day in Tokyo.
        let tokyoFirstDay = GraphFixture.utcDay(day.addingTimeInterval(86_400))
        #expect(written?["startDate"] as? String == tokyoFirstDay,
                "the range starts on \(written?["startDate"] as? String ?? "none"), the series' first day in Tokyo is \(tokyoFirstDay)")
    }

    enum EndOnlyChange: String, CaseIterable, CustomTestStringConvertible {
        case newCount, untilAdded, countToUntil
        var testDescription: String { rawValue }
    }

    /// The series' own pattern with only its end changed ("make it nine times",
    /// "end it in two months") is a new rule: it is written, with the new end.
    @Test("a whole-series edit that changes only the series' end writes the new end", arguments: EndOnlyChange.allCases)
    func endOnlyChangeIsWritten(_ change: EndOnlyChange) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let stored: StoredRule = change == .untilAdded ? .weeklyNoEnd : .everyOtherDayNumbered
        var series = GraphFixture.event(id: "ser-e", online: false, recurring: true)
        series["recurrence"] = stored.recurrence(start: GraphFixture.start)
        let graph = FakeGraphCalendar([series])
        graph.install(on: http)
        let provider = makeProvider(http)
        let read = try #require(try await provider.getEvent(eventId: "ser-e").recurrence?.first)
        let endDay = GraphFixture.utcDay(GraphFixture.start.addingTimeInterval(60 * 86_400))
        let untilPart = "UNTIL=" + endDay.replacingOccurrences(of: "-", with: "")
        let edited: String
        switch change {
        case .newCount:
            #expect(read.contains("COUNT=6"), "the read rule is \(read)")
            edited = read.replacingOccurrences(of: "COUNT=6", with: "COUNT=9")
        case .untilAdded:
            #expect(!read.contains("UNTIL") && !read.contains("COUNT"), "the read rule is \(read)")
            edited = read + ";" + untilPart
        case .countToUntil:
            #expect(read.contains("COUNT=6"), "the read rule is \(read)")
            edited = read.replacingOccurrences(of: "COUNT=6", with: untilPart)
        }
        var patch = GCalEventInput()
        patch.recurrence = [edited]

        _ = try await provider.updateEvent(eventId: "ser-e", event: patch)

        #expect(graph.patches("ser-e").contains { $0["recurrence"] != nil }, "\(change): the new end was not written")
        let after = try #require(graph.event("ser-e"))
        let recurrence = try #require(after["recurrence"] as? [String: Any])
        let pattern = recurrence["pattern"] as? [String: Any]
        let wasPattern = stored.recurrence(start: GraphFixture.start)["pattern"] as? [String: Any]
        #expect(pattern?["type"] as? String == wasPattern?["type"] as? String
                && pattern?["interval"] as? Int == wasPattern?["interval"] as? Int
                && Set(pattern?["daysOfWeek"] as? [String] ?? []) == Set(wasPattern?["daysOfWeek"] as? [String] ?? []),
                "\(change): the pattern changed")
        let range = recurrence["range"] as? [String: Any]
        switch change {
        case .newCount:
            #expect(range?["type"] as? String == "numbered" && range?["numberOfOccurrences"] as? Int == 9,
                    "\(change): the range is \(canonical(range))")
        case .untilAdded, .countToUntil:
            #expect(range?["type"] as? String == "endDate" && range?["endDate"] as? String == endDay,
                    "\(change): the range is \(canonical(range))")
        }
    }

    /// A series whose stored zone TabMail does not recognize: a rule edit, whose
    /// end would be dated in that zone, is refused by the zone's name and nothing
    /// is written.
    @Test("a rule edit of a series stored in an unrecognized zone is refused by the zone's name and writes nothing")
    func ruleEditInUnrecognizedZoneIsRefused() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var series = GraphFixture.event(id: "ser-cz", online: false, recurring: true)
        var recurrence = try #require(series["recurrence"] as? [String: Any])
        var range = try #require(recurrence["range"] as? [String: Any])
        range["recurrenceTimeZone"] = "Customized Time Zone"
        recurrence["range"] = range
        series["recurrence"] = recurrence
        let graph = FakeGraphCalendar([series])
        graph.install(on: http)
        let before = try #require(graph.event("ser-cz"))
        var patch = UserCalendarEdit.rename.patch(start: GraphFixture.start)
        patch.recurrence = ["RRULE:FREQ=DAILY;COUNT=5"]

        let provider = makeProvider(http)
        let read = try await provider.getEvent(eventId: "ser-cz")
        #expect(provider.editResetsChangedOccurrences(read, edit: patch), "the card does not warn of a reset for the refused rule edit")
        var reason: String?
        do {
            _ = try await provider.updateEvent(eventId: "ser-cz", event: patch)
        } catch CalendarProviderError.notSupported(let message) {
            reason = message
        }

        #expect(reason?.contains("This event uses the time zone \"Customized Time Zone\", which TabMail does not recognize") == true,
                "the edit was not refused by the zone's name: \(reason ?? "not refused")")
        #expect(graph.patches("ser-cz").isEmpty, "the refused edit wrote \(graph.patches("ser-cz").count) PATCHes")
        let after = try #require(graph.event("ser-cz"))
        expectOnlyEdited(nil, before: before, after: after, label: "refused edit")
    }

    enum RuleEdit: String, CaseIterable, CustomTestStringConvertible {
        case resent, renameOnly, newEnd, newInterval, newKind, timeMove, timeMoveWithResentRule
        case ownTimeResent, ownTimeResentWithRename, sameInstantOtherZone, sameInstantOtherZoneWithRename, endOnly
        var testDescription: String { rawValue }

        /// Whether the edit resets the series' changed occurrences: a rule change, or a start or
        /// end at another instant than the series' own (the same instant under another zone label
        /// is its own, and is not sent).
        var resets: Bool {
            ![.resent, .renameOnly, .ownTimeResent, .ownTimeResentWithRename, .sameInstantOtherZone, .sameInstantOtherZoneWithRename]
                .contains(self)
        }
    }

    /// The edit's card says changed occurrences may be reset exactly when the write resets
    /// them, as Graph does on any change of a series' rule, start or end: both decide from the
    /// same merge of the edit with the series, the card from the event it read.
    @Test("the card's answer to whether an edit resets changed occurrences is the write's",
          arguments: StoredRule.allCases, RuleEdit.allCases)
    func cardAnswerIsTheWrites(_ rule: StoredRule, _ edit: RuleEdit) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var series = GraphFixture.event(id: "ser-c", online: false, recurring: true)
        series["recurrence"] = rule.recurrence(start: GraphFixture.start)
        let graph = FakeGraphCalendar([series])
        graph.install(on: http)
        let provider = makeProvider(http)
        let read = try await provider.getEvent(eventId: "ser-c")
        let stored = try #require(read.recurrence?.first)
        func without(_ names: [String]) -> String {
            stored.split(separator: ";").filter { part in !names.contains { part.hasPrefix($0 + "=") } }.joined(separator: ";")
        }
        var patch = GCalEventInput()
        switch edit {
        case .resent: patch.recurrence = [stored]
        case .renameOnly: patch.summary = "Planning (renamed)"
        case .newEnd: patch.recurrence = [without(["COUNT", "UNTIL"]) + ";COUNT=3"]
        case .newInterval: patch.recurrence = [without(["INTERVAL"]) + ";INTERVAL=3"]
        case .newKind: patch.recurrence = [stored.hasPrefix("RRULE:FREQ=DAILY") ? "RRULE:FREQ=WEEKLY" : "RRULE:FREQ=DAILY"]
        case .timeMove, .timeMoveWithResentRule:
            // An hour later on the same day: no date move, so no recurrence is written.
            patch.startDateTime = GraphFixture.rfc3339(GraphFixture.start.addingTimeInterval(3_600))
            patch.startTimeZone = "UTC"
            if edit == .timeMoveWithResentRule { patch.recurrence = [stored] }
        case .ownTimeResent, .ownTimeResentWithRename:
            // The series' start and end as the read gives them.
            patch.startDateTime = read.start?.dateTime
            patch.startTimeZone = read.start?.timeZone
            patch.endDateTime = read.end?.dateTime
            patch.endTimeZone = read.end?.timeZone
            if edit == .ownTimeResentWithRename { patch.summary = "Planning (renamed)" }
        case .sameInstantOtherZone, .sameInstantOtherZoneWithRename:
            // The series' own start and end, spelled as Tokyo wall times labelled Tokyo.
            let tokyo: TimeInterval = 9 * 3_600
            patch.startDateTime = GraphFixture.naive(GraphFixture.start.addingTimeInterval(tokyo)) + "+09:00"
            patch.startTimeZone = "Asia/Tokyo"
            patch.endDateTime = GraphFixture.naive(GraphFixture.start.addingTimeInterval(1_800 + tokyo)) + "+09:00"
            patch.endTimeZone = "Asia/Tokyo"
            if edit == .sameInstantOtherZoneWithRename { patch.summary = "Planning (renamed)" }
        case .endOnly:
            // The series' own start, and an end an hour later.
            patch.startDateTime = read.start?.dateTime
            patch.startTimeZone = read.start?.timeZone
            patch.endDateTime = GraphFixture.rfc3339(GraphFixture.start.addingTimeInterval(1_800 + 3_600))
            patch.endTimeZone = "UTC"
        }

        let answer = provider.editResetsChangedOccurrences(read, edit: patch)
        _ = try await provider.updateEvent(eventId: "ser-c", event: patch)

        let label = "\(rule.rawValue), \(edit.rawValue) (\(patch.recurrence?.first ?? "no rule"))"
        let reset = graph.seriesResets > 0
        #expect(answer == reset, "\(label): the card says \(answer ? "a reset" : "no reset"), the write \(reset ? "reset" : "did not reset") the series")
        #expect(answer == edit.resets, "\(label): the card says \(answer ? "a reset" : "no reset")")
        // One decision: the card warns exactly when the PATCH carries the series' start and end
        // (a move, or beside a written rule).
        let sent = graph.patches("ser-c")
        let sentTimes = sent.contains { $0["start"] != nil || $0["end"] != nil }
        #expect(answer == sentTimes, "\(label): the card says \(answer ? "a reset" : "no reset"), the PATCH \(sentTimes ? "carries" : "does not carry") start and end")
        if [.ownTimeResent, .ownTimeResentWithRename, .sameInstantOtherZone, .sameInstantOtherZoneWithRename].contains(edit) {
            #expect(sent.allSatisfy { $0["start"] == nil && $0["end"] == nil && $0["recurrence"] == nil },
                    "\(label): the series' own times sent back were PATCHed: \(sent.map { $0.keys.sorted() })")
            let renamed = [.ownTimeResentWithRename, .sameInstantOtherZoneWithRename].contains(edit)
            #expect(sent.count == (renamed ? 1 : 0), "\(label): \(sent.count) PATCHes")
        }
    }

    enum ZoneLabel: String, CaseIterable, CustomTestStringConvertible {
        case ianaForStoredWindows, otherZone, unresolvable
        var testDescription: String { rawValue }

        /// The label the edit gives the series' own wall times.
        var label: String {
            switch self {
            case .ianaForStoredWindows: "America/Los_Angeles"
            case .otherZone: "America/New_York"
            case .unresolvable: "Customized Time Zone"
            }
        }

        /// A series' time moves when its wall time or its resolved zone changes; a label that does
        /// not resolve is a move.
        var moves: Bool { self != .ianaForStoredWindows }
    }

    /// A series stored with Graph's Windows zone name, renamed with its own wall times labelled
    /// by an IANA name (as the tools write them): the same zone, so nothing moves, and the write
    /// sends no start, end or recurrence. Another zone, or a label that does not resolve, is a
    /// move (its recurrence may be written too, when the move changes the device's date), and the
    /// card's answer is the write's.
    @Test("a series' own wall times under another name for its zone are no move; another or unknown zone is one",
          arguments: ZoneLabel.allCases)
    func zoneLabelsCompareByResolvedZone(_ zone: ZoneLabel) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var series = GraphFixture.event(id: "ser-w", online: false, recurring: true)
        series["start"] = ["dateTime": GraphFixture.naive(GraphFixture.start) + ".0000000", "timeZone": "Pacific Standard Time"]
        series["end"] = ["dateTime": GraphFixture.naive(GraphFixture.start.addingTimeInterval(1_800)) + ".0000000",
                         "timeZone": "Pacific Standard Time"]
        let graph = FakeGraphCalendar([series])
        graph.install(on: http)
        let provider = makeProvider(http)
        let read = try await provider.getEvent(eventId: "ser-w")
        var patch = GCalEventInput()
        patch.summary = "Planning (renamed)"
        patch.startDateTime = GraphFixture.naive(GraphFixture.start)
        patch.startTimeZone = zone.label
        patch.endDateTime = GraphFixture.naive(GraphFixture.start.addingTimeInterval(1_800))
        patch.endTimeZone = zone.label

        let answer = provider.editResetsChangedOccurrences(read, edit: patch)
        _ = try await provider.updateEvent(eventId: "ser-w", event: patch)

        let sent = graph.patches("ser-w")
        let reset = graph.seriesResets > 0
        #expect(sent.count == 1, "\(zone): \(sent.count) PATCHes")
        #expect(answer == zone.moves, "\(zone): the card says \(answer ? "a reset" : "no reset")")
        #expect(answer == reset, "\(zone): the card says \(answer ? "a reset" : "no reset"), the write \(reset ? "reset" : "did not reset") the series")
        let sentTimes = sent.contains { $0["start"] != nil || $0["end"] != nil }
        #expect(sentTimes == zone.moves, "\(zone): the PATCH \(sentTimes ? "sent" : "did not send") start and end: \(sent.map { $0.keys.sorted() })")
        #expect(answer == sentTimes, "\(zone): the card and the PATCH disagree")
        #expect(reset == zone.moves, "\(zone): \(graph.seriesResets) resets")
        if !zone.moves {
            #expect(sent.allSatisfy { $0["recurrence"] == nil }, "\(zone): the PATCH carried a recurrence")
        }
    }

    enum KindChange: String, CaseIterable, CustomTestStringConvertible {
        case timedToAllDay, allDayToTimed
        var testDescription: String { rawValue }
    }

    /// A series at 00:00 UTC made all-day on the same date, or the reverse: the start and end
    /// write the same wall times and zone, and only `isAllDay` differs. That is a move: the PATCH
    /// sends the start, the end and the new kind, and the card warns.
    @Test("a series made all-day on the same date at 00:00 UTC, or the reverse, is sent and warned of",
          arguments: KindChange.allCases)
    func allDayChangeIsAMove(_ change: KindChange) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let day = GraphFixture.utcDay(GraphFixture.start)
        let next = GraphFixture.utcDay(GraphFixture.start.addingTimeInterval(86_400))
        var series = GraphFixture.event(id: "ser-k", online: false, recurring: true, allDay: change == .allDayToTimed)
        series["start"] = ["dateTime": day + "T00:00:00.0000000", "timeZone": "UTC"]
        series["end"] = ["dateTime": next + "T00:00:00.0000000", "timeZone": "UTC"]
        let graph = FakeGraphCalendar([series])
        graph.install(on: http)
        let provider = makeProvider(http)
        let read = try await provider.getEvent(eventId: "ser-k")
        var patch = GCalEventInput()
        switch change {
        case .timedToAllDay:
            patch.startDate = day
            patch.endDate = next
        case .allDayToTimed:
            patch.startDateTime = day + "T00:00:00Z"
            patch.startTimeZone = "UTC"
            patch.endDateTime = next + "T00:00:00Z"
            patch.endTimeZone = "UTC"
        }

        let answer = provider.editResetsChangedOccurrences(read, edit: patch)
        _ = try await provider.updateEvent(eventId: "ser-k", event: patch)

        let sent = graph.patches("ser-k")
        #expect(answer, "\(change): the card does not warn")
        #expect(graph.seriesResets > 0, "\(change): the fake counted no reset")
        #expect(sent.contains { $0["start"] != nil && $0["end"] != nil && $0["isAllDay"] as? Bool == (change == .timedToAllDay) },
                "\(change): the change was not sent: \(sent.map { $0.keys.sorted() })")
    }

    enum ReadZone: String, CaseIterable, CustomTestStringConvertible {
        case daylightSavingSeriesReadWithout, seriesWithoutReadWithDaylightSaving
        var testDescription: String { rawValue }

        /// The zone Graph keeps the series in, by its Windows name.
        var stored: String { self == .daylightSavingSeriesReadWithout ? "Eastern Standard Time" : "Tokyo Standard Time" }
        /// The device's zone, which a read asks Graph to give the times in, by both its names.
        var read: (windows: String, iana: String) {
            self == .daylightSavingSeriesReadWithout
                ? ("Tokyo Standard Time", "Asia/Tokyo") : ("Eastern Standard Time", "America/New_York")
        }
    }

    /// Reads ask Graph for times in the device's zone, so a series Graph keeps in one zone reads
    /// back in another, with or without daylight saving on either side. A rename that echoes the
    /// read times, labelled with the device's zone as the tools write them, restates the series'
    /// own instants: nothing moves, so the PATCH sends no start, end or recurrence, the card does
    /// not warn, nothing is reset, and the series keeps the zone Graph keeps it in.
    @Test("a series renamed with the times it was read with, in the zone it was read in, keeps its time and zone",
          arguments: ReadZone.allCases)
    func readTimesEchoedAreNoMove(_ zone: ReadZone) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let readZone = try #require(TimeZone(identifier: zone.read.iana))
        let start = GraphFixture.start
        let end = GraphFixture.start.addingTimeInterval(1_800)
        var series = GraphFixture.event(id: "ser-t", online: false, recurring: true)
        // As a read asking for the device's zone gives a series Graph keeps in another.
        series["start"] = ["dateTime": GraphFixture.wall(start, in: zone.read.iana) + ".0000000", "timeZone": zone.read.windows]
        series["end"] = ["dateTime": GraphFixture.wall(end, in: zone.read.iana) + ".0000000", "timeZone": zone.read.windows]
        series["originalStartTimeZone"] = zone.stored
        series["originalEndTimeZone"] = zone.stored
        var recurrence = try #require(series["recurrence"] as? [String: Any])
        var range = try #require(recurrence["range"] as? [String: Any])
        range["recurrenceTimeZone"] = zone.stored
        recurrence["range"] = range
        series["recurrence"] = recurrence
        let graph = FakeGraphCalendar([series])
        graph.install(on: http)
        let before = try #require(graph.event("ser-t"))
        let provider = makeProvider(http)
        let read = try await provider.getEvent(eventId: "ser-t")
        var patch = GCalEventInput()
        patch.summary = "Planning (renamed)"
        patch.startDateTime = try #require(read.start?.dateTime.flatMap { Date.fromISO8601($0) }).iso8601String(timeZone: readZone)
        patch.startTimeZone = zone.read.iana
        patch.endDateTime = try #require(read.end?.dateTime.flatMap { Date.fromISO8601($0) }).iso8601String(timeZone: readZone)
        patch.endTimeZone = zone.read.iana

        let answer = provider.editResetsChangedOccurrences(read, edit: patch)
        _ = try await provider.updateEvent(eventId: "ser-t", event: patch)

        let sent = graph.patches("ser-t")
        #expect(!answer, "\(zone): the card warns of a reset for the series' own times")
        #expect(sent.count == 1 && sent.allSatisfy { $0["start"] == nil && $0["end"] == nil && $0["recurrence"] == nil },
                "\(zone): the rename sent \(sent.map { $0.keys.sorted() })")
        #expect(graph.seriesResets == 0, "\(zone): \(graph.seriesResets) resets")
        let after = try #require(graph.event("ser-t"))
        for key in ["start", "end", "originalStartTimeZone", "originalEndTimeZone", "recurrence"] {
            #expect(canonical(after[key]) == canonical(before[key]), "\(zone): the rename changed '\(key)': \(canonical(after[key]))")
        }
        #expect(after["subject"] as? String == "Planning (renamed)", "\(zone): the rename was not written")
    }

    /// The card's stand-in for the stored recurrence (the event's RRULE rebuilt in Graph's form)
    /// means the rule Graph stores: for every stored rule kind, it is `sameRule` with the raw
    /// recurrence the write compares with, so the card and the write judge an edit's rule against
    /// the same rule.
    @Test("the card's rebuilt stored rule is the write's raw stored recurrence", arguments: StoredRule.allCases)
    func cardBaselineIsTheStoredRule(_ rule: StoredRule) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var series = GraphFixture.event(id: "ser-b", online: false, recurring: true)
        series["recurrence"] = rule.recurrence(start: GraphFixture.start)
        let graph = FakeGraphCalendar([series])
        graph.install(on: http)
        let provider = makeProvider(http)
        let read = try await provider.getEvent(eventId: "ser-b")
        let raw = try #require(graph.event("ser-b")?["recurrence"] as? [String: Any])

        let baseline = try #require(provider.storedRuleBaseline(read), "\(rule): the card has no stand-in for the stored rule")
        #expect(ExchangeCalendarProvider.sameRule(baseline.recurrence, as: raw),
                "\(rule): the card's rule \(canonical(baseline.recurrence)) is not the stored \(canonical(raw))")
    }

    enum StartMove: String, CaseIterable, CustomTestStringConvertible {
        case weeklyToAnotherWeekday, monthlyToAnotherDay, untilEndDayShifts
        var testDescription: String { rawValue }
    }

    /// The same, for a rule edit that also moves the series' start: a rule that names no day
    /// takes it from the new start, and an UNTIL earlier in its day than the new start time ends
    /// the series a day sooner, so the write's rule decision is taken beside the new start.
    @Test("the card's answer is the write's for a rule edit that also moves the series' start",
          arguments: StartMove.allCases)
    func cardAnswerIsTheWritesWithStartMove(_ move: StartMove) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let start = GraphFixture.start
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = GraphFixture.utc
        let endDay = GraphFixture.utcDay(start.addingTimeInterval(20 * 86_400))
        let endDayCompact = endDay.replacingOccurrences(of: "-", with: "")
        let pattern: [String: Any]
        let rule: String
        let newStart: Date
        switch move {
        case .weeklyToAnotherWeekday:
            pattern = ["type": "weekly", "interval": 1, "month": 0, "dayOfMonth": 0,
                       "daysOfWeek": [GraphFixture.weekday(start)], "firstDayOfWeek": "monday", "index": "first"]
            rule = "RRULE:FREQ=WEEKLY;UNTIL=\(endDayCompact)"
            newStart = start.addingTimeInterval(86_400)
        case .monthlyToAnotherDay:
            pattern = ["type": "absoluteMonthly", "interval": 1, "month": 0, "dayOfMonth": cal.component(.day, from: start),
                       "daysOfWeek": [String](), "firstDayOfWeek": "monday", "index": "first"]
            rule = "RRULE:FREQ=MONTHLY;UNTIL=\(endDayCompact)"
            newStart = start.addingTimeInterval(86_400)
        case .untilEndDayShifts:
            // The series' last day at an hour after its start time: still the stored end
            // beside the stored start, the day before beside a start two hours later.
            pattern = ["type": "daily", "interval": 1, "month": 0, "dayOfMonth": 0,
                       "daysOfWeek": [String](), "firstDayOfWeek": "monday", "index": "first"]
            let until = start.addingTimeInterval(20 * 86_400 + 3_600)
            rule = "RRULE:FREQ=DAILY;UNTIL=" + GraphFixture.naive(until)
                .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "") + "Z"
            newStart = start.addingTimeInterval(2 * 3_600)
        }
        let storedRange: [String: Any] = ["type": "endDate", "startDate": GraphFixture.utcDay(start), "endDate": endDay,
                                          "numberOfOccurrences": 0, "recurrenceTimeZone": "UTC"]
        var series = GraphFixture.event(id: "ser-m", start: start, online: false, recurring: true)
        series["recurrence"] = ["pattern": pattern, "range": storedRange] as [String: Any]
        let graph = FakeGraphCalendar([series])
        graph.install(on: http)
        let provider = makeProvider(http)
        let read = try await provider.getEvent(eventId: "ser-m")
        var patch = GCalEventInput()
        patch.recurrence = [rule]
        patch.startDateTime = GraphFixture.rfc3339(newStart)
        patch.startTimeZone = "UTC"

        let answer = provider.editResetsChangedOccurrences(read, edit: patch)
        _ = try await provider.updateEvent(eventId: "ser-m", event: patch)

        // A rule written, as opposed to the stored one written back with its range's start
        // date moved (a date move with the series' own rule).
        var wasRange = storedRange
        wasRange.removeValue(forKey: "startDate")
        let wroteRule = graph.patches("ser-m").contains { sent in
            guard let written = sent["recurrence"] as? [String: Any] else { return false }
            var range = written["range"] as? [String: Any] ?? [:]
            range.removeValue(forKey: "startDate")
            return canonical(written["pattern"]) != canonical(pattern) || canonical(range) != canonical(wasRange)
        }
        #expect(wroteRule, "\(move) (\(rule)): the write judged the rule the stored one beside the new start")
        let reset = graph.seriesResets > 0
        #expect(answer == reset, "\(move) (\(rule)): the card says \(answer ? "a reset" : "no reset"), the write \(reset ? "reset" : "did not reset") the series")
        #expect(answer, "\(move) (\(rule)): the card says no reset")
    }

    enum UnmappedPattern: String, CaseIterable, CustomTestStringConvertible {
        case weeklyWithNoDays, relativeMonthlyWithNoIndex
        var testDescription: String { rawValue }
    }

    /// A stored pattern that its RRULE does not say exactly (it does not come back the same
    /// through one): the card cannot tell the rule the edit re-sends is the stored one, so it
    /// answers "changed", as the write, comparing with the stored pattern, writes the rule.
    /// A relative pattern stored with no index is the exception: Graph's default index is
    /// `first`, which the read rule says (`storedIndex`), so it is the same rule and nothing is
    /// sent.
    @Test("a series whose pattern its RRULE does not say exactly answers changed, as its write writes the rule; one with no index is its own rule",
          arguments: UnmappedPattern.allCases)
    func unmappedPatternAnswersChanged(_ kind: UnmappedPattern) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let pattern: [String: Any]
        switch kind {
        case .weeklyWithNoDays:
            pattern = ["type": "weekly", "interval": 1, "month": 0, "dayOfMonth": 0,
                       "daysOfWeek": [String](), "firstDayOfWeek": "monday", "index": "first"]
        case .relativeMonthlyWithNoIndex:
            pattern = ["type": "relativeMonthly", "interval": 1, "month": 0, "dayOfMonth": 0,
                       "daysOfWeek": ["tuesday"], "firstDayOfWeek": "monday"]
        }
        var series = GraphFixture.event(id: "ser-u", online: false, recurring: true)
        series["recurrence"] = [
            "pattern": pattern,
            "range": ["type": "noEnd", "startDate": GraphFixture.utcDay(GraphFixture.start), "endDate": "0001-01-01",
                      "numberOfOccurrences": 0, "recurrenceTimeZone": "UTC"],
        ] as [String: Any]
        let graph = FakeGraphCalendar([series])
        graph.install(on: http)
        let provider = makeProvider(http)
        let read = try await provider.getEvent(eventId: "ser-u")
        var patch = GCalEventInput()
        patch.recurrence = [try #require(read.recurrence?.first)]

        let answer = provider.editResetsChangedOccurrences(read, edit: patch)
        _ = try await provider.updateEvent(eventId: "ser-u", event: patch)

        let reset = graph.seriesResets > 0
        switch kind {
        case .weeklyWithNoDays:
            #expect(answer, "\(kind): the card says the re-sent rule is the stored one")
        case .relativeMonthlyWithNoIndex:
            // A missing index is Graph's default `first` (measured: Graph returns it): the read rule
            // says it, so the re-sent rule is the stored one, and nothing is sent.
            #expect(!answer, "\(kind): the card says the re-sent rule changes the series")
            #expect(graph.patches("ser-u").isEmpty, "\(kind): \(graph.patches("ser-u").count) PATCHes")
        }
        #expect(answer == reset, "\(kind): the card says \(answer ? "a reset" : "no reset"), the write \(reset ? "reset" : "did not reset") the series")
    }

    /// A series kept in Tokyo whose start Graph gives at 20:00 UTC, 05:00 the next day in
    /// Tokyo, on that day's weekday. A weekly rule that names no day, as the assistant may
    /// write it, recurs on the start's weekday in the series' zone: the series' own rule.
    @Test("a weekly rule with no day, for a series kept in another zone, is its weekday there and the stored rule")
    func bareWeeklyIsTheSeriesWeekday() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = GraphFixture.utc
        let day = cal.startOfDay(for: Date().addingTimeInterval(30 * 86_400))
        let start = day.addingTimeInterval(20 * 3_600)
        let tokyoDay = day.addingTimeInterval(86_400)
        var series = GraphFixture.event(id: "ser-tw", start: start, online: false, recurring: true)
        series["recurrence"] = [
            "pattern": ["type": "weekly", "interval": 1, "month": 0, "dayOfMonth": 0,
                        "daysOfWeek": [GraphFixture.weekday(tokyoDay.addingTimeInterval(12 * 3_600))],
                        "firstDayOfWeek": "monday", "index": "first"],
            "range": ["type": "noEnd", "startDate": GraphFixture.utcDay(tokyoDay), "endDate": "0001-01-01",
                      "numberOfOccurrences": 0, "recurrenceTimeZone": "Tokyo Standard Time"],
        ] as [String: Any]
        let graph = FakeGraphCalendar([series])
        graph.install(on: http)
        let before = try #require(graph.event("ser-tw"))
        let provider = makeProvider(http)
        let read = try await provider.getEvent(eventId: "ser-tw")
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=WEEKLY"]

        #expect(!provider.editResetsChangedOccurrences(read, edit: patch), "the card says the series' own weekday resets changed occurrences")
        _ = try await provider.updateEvent(eventId: "ser-tw", event: patch)

        #expect(graph.patches("ser-tw").allSatisfy { $0["recurrence"] == nil }, "the series' own rule was written")
        #expect(graph.seriesResets == 0, "the edit reset the series' exceptions")
        let after = try #require(graph.event("ser-tw"))
        expectOnlyEdited(nil, before: before, after: after, label: "bare weekly")
    }

    /// A series whose range names no zone: a rule change labels the range with
    /// the zone the start is written in, not UTC.
    @Test("a rule change on a series stored with no zone labels its range with the start's zone",
          arguments: ["absent", "empty"])
    func ruleChangeWithNoStoredZone(_ storedZone: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let zone = "America/New_York"
        var series = GraphFixture.event(id: "ser-nz", online: false, recurring: true)
        series["start"] = ["dateTime": GraphFixture.wall(GraphFixture.start, in: zone), "timeZone": zone]
        series["end"] = ["dateTime": GraphFixture.wall(GraphFixture.start.addingTimeInterval(1_800), in: zone), "timeZone": zone]
        var recurrence = try #require(series["recurrence"] as? [String: Any])
        var range = try #require(recurrence["range"] as? [String: Any])
        if storedZone == "empty" {
            range["recurrenceTimeZone"] = ""
        } else {
            range.removeValue(forKey: "recurrenceTimeZone")
        }
        recurrence["range"] = range
        series["recurrence"] = recurrence
        let graph = FakeGraphCalendar([series])
        graph.install(on: http)
        var patch = GCalEventInput()
        patch.recurrence = ["RRULE:FREQ=DAILY;COUNT=5"]

        _ = try await makeProvider(http).updateEvent(eventId: "ser-nz", event: patch)

        let after = try #require(graph.event("ser-nz"))
        let start = try #require(after["start"] as? [String: Any])
        #expect(start["timeZone"] as? String == zone, "the start is written in \(start["timeZone"] as? String ?? "none")")
        let written = ((after["recurrence"] as? [String: Any])?["range"] as? [String: Any])?["recurrenceTimeZone"] as? String
        #expect(written == zone, "\(storedZone) stored zone: the range is labelled \(written ?? "none"), the start \(zone)")
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
        #expect(graph.seriesResets == 1, "a start move did not reset the series' exceptions, as Graph does")
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

    /// A start written without an offset or seconds (`…T10:00`) is the wall time in
    /// the edit's zone, dated on the device like any other start.
    @Test("a whole series moved to another date by a start written without an offset keeps its recurrence at the new date")
    func wholeSeriesMovedByNaiveStart() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let before = try #require(graph.event("ser-1"))
        let newStart = GraphFixture.start.addingTimeInterval(7 * 86_400)
        let patch = try CalendarToolHelpers.buildGCalEventInput([
            "start_iso": .string(String(GraphFixture.naive(newStart).prefix(16))),
            "end_iso": .string(String(GraphFixture.naive(newStart.addingTimeInterval(1_800)).prefix(16))),
            "timezone": .string("UTC"),
        ], isAllDay: false)

        _ = try await makeProvider(http).updateEvent(eventId: "ser-1", event: patch)

        let after = try #require(graph.event("ser-1"))
        let now = try #require(after["recurrence"] as? [String: Any], "the series lost its recurrence")
        #expect(graph.patches("ser-1").contains { $0["recurrence"] != nil }, "the range's start date was not moved")
        #expect((now["range"] as? [String: Any])?["startDate"] as? String == GraphFixture.utcDay(newStart))
        #expect(canonical(now["pattern"]) == canonical((before["recurrence"] as? [String: Any])?["pattern"]), "the move changed the pattern")
    }

    /// A start the assistant spells with an offset names that instant, and one
    /// without names the wall time in the edit's zone: Graph stores that instant,
    /// and the series' date is that stored start's, read on the device. A move
    /// within the device's day writes no recurrence, and a move to another day
    /// writes the range at that day.
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
            "start_iso": .string(spelling.spell(move.newStart, label: zone)),
            "end_iso": .string(spelling.spell(move.newStart.addingTimeInterval(1_800), label: zone)),
            "timezone": .string(zone),
        ], isAllDay: false)

        _ = try await makeProvider(http).updateEvent(eventId: "ser-z", event: patch)

        let after = try #require(graph.event("ser-z"))
        let start = try #require(after["start"] as? [String: Any])
        #expect(GraphFixture.instant(start) == move.newStart,
                "Graph stores \(start["dateTime"] as? String ?? "none") in \(start["timeZone"] as? String ?? "none"), the user moved it to \(move.newStart)")
        #expect(GraphFixture.instant(after["end"] as? [String: Any]) == move.newStart.addingTimeInterval(1_800), "the end is not the one given")
        let storedDay = try #require(GraphFixture.deviceDay(wall: start["dateTime"] as? String ?? "",
                                                            in: start["timeZone"] as? String ?? ""))
        let seriesDay = GraphFixture.deviceDay(seriesStart)
        #expect((storedDay != seriesDay) == move.movesDate, "the series is stored on \(storedDay), was on \(seriesDay)")
        let wroteRecurrence = graph.patches("ser-z").contains { $0["recurrence"] != nil }
        #expect(graph.seriesResets == 1, "a start move did not reset the series' exceptions, as Graph does")
        if storedDay == seriesDay {
            #expect(!wroteRecurrence, "a move within the device's day wrote a recurrence")
        } else {
            #expect(wroteRecurrence, "a move to another day kept the range's old start date")
        }
        let range = (after["recurrence"] as? [String: Any])?["range"] as? [String: Any]
        #expect(range?["startDate"] as? String == storedDay,
                "the range starts on \(range?["startDate"] as? String ?? "none"), the series on \(storedDay)")
    }

    /// "move it to 23:30": a start alone keeps the event's length. However the start
    /// is spelled, Graph stores the instant it names, and the end is that instant
    /// plus the length, so the end never lands before the start or hours late.
    @Test("an event moved by a start alone, spelled with or without an offset, starts there and keeps its length",
          arguments: StartSpelling.allCases)
    func startOnlyMoveBySpelledStart(_ spelling: StartSpelling) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let before = try #require(graph.event("ev-plain"))
        let length = try #require(GraphFixture.instant(before["end"] as? [String: Any])).timeIntervalSince(
            try #require(GraphFixture.instant(before["start"] as? [String: Any])))
        let newStart = GraphFixture.onDevice(days: 1, hour: 23).addingTimeInterval(1_800)
        let patch = try CalendarToolHelpers.buildGCalEventInput([
            "start_iso": .string(spelling.spell(newStart, label: GraphFixture.farEast)),
            "timezone": .string(GraphFixture.farEast),
        ], isAllDay: false)

        _ = try await makeProvider(http).updateEvent(eventId: "ev-plain", event: patch)

        let after = try #require(graph.event("ev-plain"))
        let start = after["start"] as? [String: Any]
        let end = after["end"] as? [String: Any]
        #expect(GraphFixture.instant(start) == newStart,
                "Graph stores \(start?["dateTime"] as? String ?? "none") in \(start?["timeZone"] as? String ?? "none"), the user moved it to \(newStart)")
        #expect(GraphFixture.instant(end) == newStart.addingTimeInterval(length),
                "the end is \(end?["dateTime"] as? String ?? "none") in \(end?["timeZone"] as? String ?? "none"), not the start plus the event's length")
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

    /// An all-day edit is dated as spelled, never by the day an offset's instant falls on in
    /// the edit's zone: Graph stores the spelled day, midnight to midnight.
    @Test("an all-day series moved by a date spelled with a time and an offset lands on the spelled date",
          arguments: AllDaySpelling.allCases)
    func allDaySeriesMovedBySpelledDate(_ spelling: AllDaySpelling) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = FakeGraphCalendar([GraphFixture.event(id: "ser-ad", online: false, recurring: true, allDay: true)])
        graph.install(on: http)
        let patch = try CalendarToolHelpers.buildGCalEventInput([
            "start_iso": .string(spelling.spell(AllDaySpelling.day)),
            "end_iso": .string(spelling.spell(AllDaySpelling.nextDay)),
            "timezone": .string(AllDaySpelling.label),
        ], isAllDay: true)

        _ = try await makeProvider(http).updateEvent(eventId: "ser-ad", event: patch)

        let after = try #require(graph.event("ser-ad"))
        let start = (after["start"] as? [String: Any])?["dateTime"] as? String
        let end = (after["end"] as? [String: Any])?["dateTime"] as? String
        #expect(start?.hasPrefix(AllDaySpelling.day) == true, "the series starts on \(start ?? "none"), spelled \(AllDaySpelling.day)")
        #expect(end?.hasPrefix(AllDaySpelling.nextDay) == true, "the series ends on \(end ?? "none"), spelled \(AllDaySpelling.nextDay)")
        #expect(((after["recurrence"] as? [String: Any])?["range"] as? [String: Any])?["startDate"] as? String == AllDaySpelling.day)
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

    @Test("in the fake, as measured live, an attendee list with an entry that has no status is refused with 405 and changes nothing")
    func fakeRefusesAttendeeWithoutStatus() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let before = try #require(graph.event("ev-online"))
        let body = try JSONSerialization.data(withJSONObject: [
            "attendees": [["emailAddress": ["address": "cy@example.com", "name": "Cy"], "type": "required"]],
        ])
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/events/ev-online")!)
        request.httpMethod = "PATCH"
        request.httpBody = body
        let (data, response) = try await http.session.data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 405)
        let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        #expect(error?["code"] as? String == "UnknownError")
        #expect(graph.patches("ev-online").isEmpty)
        #expect(canonical(graph.event("ev-online")?["attendees"]) == canonical(before["attendees"]))
    }

    @Test("an attendee whose address is stored in mixed case keeps its type and answer when the attendees are written")
    func mixedCaseAttendeeKeepsItsType() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        var event = GraphFixture.event(id: "ev-case", online: false)
        event["attendees"] = GraphFixture.attendees + [
            ["emailAddress": ["address": "Optional.Person@Example.com", "name": "Optional Person"], "type": "optional",
             "status": ["response": "declined", "time": GraphFixture.answeredAt]],
        ]
        let graph = FakeGraphCalendar([event])
        graph.install(on: http)
        var patch = UserCalendarEdit.addAttendee.patch(start: GraphFixture.start)
        // Asked for in another letter case than Graph stores.
        patch.attendees?.append((email: "optional.person@example.com", name: "Optional Person"))

        _ = try await makeProvider(http).updateEvent(eventId: "ev-case", event: patch)

        let after = try #require(graph.event("ev-case"))
        #expect(attendeeTypes(after)["optional.person@example.com"] == "optional",
                "the mixed-case attendee is \(attendeeTypes(after)["optional.person@example.com"] ?? "gone")")
        #expect(attendeeTypes(after)["bo@example.com"] == "optional")
        let stored = try #require(event["attendees"] as? [[String: Any]])
        #expect(canonical(attendeeEntries(after)["optional.person@example.com"]) == canonical(stored.last),
                "the mixed-case attendee was not written as stored")
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
        for property in watchedProperties where property != "body" && property != "bodyPreview" {
            #expect(canonical(after[property]) == canonical(before[property]), "the round trip changed \(property)")
        }
        #expect(after["isOnlineMeeting"] as? Bool == true, "the edit turned the online meeting off")
        let was = try #require((before["body"] as? [String: Any])?["content"] as? String)
        let content = try #require((after["body"] as? [String: Any])?["content"] as? String)
        let section = try #require(was.range(of: GraphFixture.joinSection).map { String(was[$0.lowerBound...]) })
        #expect(content.hasSuffix(section), "the join section was not kept as stored")
        // The notes' link is still a link, not its `[label](url)` text.
        #expect(read.contains("[linked doc](https://example.com/doc)"), "setup: the read gives the link as \(read)")
        #expect(content.contains("<a href=\"https://example.com/doc\">linked doc</a>"), "the link was not written as a link")
        #expect(!content.contains("[linked doc]"), "the link was written as its text")
        #expect(try await provider.getEvent(eventId: "ev-online").description == read + "\nAdded line")
    }

    @Test("notes with links and runs of spaces read back as they were written", arguments: ["ev-online", "ev-plain"])
    func notesReadBackAsWritten(_ id: String) async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let provider = makeProvider(http)
        let online = try #require(graph.event(id))["isOnlineMeeting"] as? Bool
        // The third line is a link as a read writes it, with every escape a label or a
        // destination can carry.
        let notes = "Plan  with [Terms &amp; Conditions](https://example.com/doc?a=1&b=2)\n"
            + "   indented, [mail me](mailto:ana@example.com) or [call](tel:+15550100)\n"
            + #"[a\_b \*c\* \`d\` \~e\~ \<f\> \\g \[h\]](http://example.com/p\(1\)\;x\<y\>\\z)"#
            + "\n\nlast   line"
        var patch = GCalEventInput()
        patch.description = notes

        _ = try await provider.updateEvent(eventId: id, event: patch)

        #expect(try #require(graph.event(id))["isOnlineMeeting"] as? Bool == online, "\(id): the meeting changed")
        #expect(try await provider.getEvent(eventId: id).description == notes, "\(id)")
    }

    @Test("a plain event's description read and written back keeps its link as a link")
    func plainDescriptionRoundTrip() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let graph = GraphFixture.calendar()
        graph.install(on: http)
        let provider = makeProvider(http)
        let read = try #require(try await provider.getEvent(eventId: "ev-plain").description)
        #expect(read.contains("[link](https://example.com/doc)"), "setup: the read gives the link as \(read)")
        var patch = GCalEventInput()
        patch.description = read

        _ = try await provider.updateEvent(eventId: "ev-plain", event: patch)

        let content = try #require((graph.event("ev-plain")?["body"] as? [String: Any])?["content"] as? String)
        #expect(content.contains("<a href=\"https://example.com/doc\">link</a>") && !content.contains("[link]"),
                "the link was written as its text: \(content)")
        #expect(try await provider.getEvent(eventId: "ev-plain").description == read)
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

    @Test("an online meeting whose join section is not recognised gets the description as its whole body, as any event does")
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
        #expect(sent["contentType"] as? String == "html")
        #expect(sent["content"] as? String == "New notes<br>\r\nSecond line")
    }
}
