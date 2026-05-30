/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Demo Mode calendar provider — implements `CalendarProvider` against the
/// `demoCalendarEvent` GRDB table. No network, no `EKEventStore` access.
///
/// All seeded + user-created events live entirely in the demoCalendarEvent
/// table and are wiped by `DemoSeed.wipe()` on demo exit. The user's real
/// iPhone calendar is not touched.
actor DemoCalendarProvider: CalendarProvider {
    private let accountId: String

    init(accountId: String) {
        self.accountId = accountId
    }

    private struct DemoCalendarEventRow: FetchableRecord, Decodable {
        let id: String
        let accountId: String
        let calendarId: String
        let title: String
        let location: String?
        let description: String?
        let startMs: Int64
        let endMs: Int64
        let allDay: Int
        let attendeesJSON: String?
    }

    func listCalendars() async throws -> [GCalCalendar] {
        // Single primary calendar for demo. UI looks like a real Gmail-style
        // primary calendar.
        return [
            GCalCalendar(
                id: "primary",
                summary: "Demo Calendar",
                primary: true,
                accessRole: "owner",
                backgroundColor: "#4285F4",
                selected: true
            ),
        ]
    }

    func primaryCalendarId() async throws -> String {
        "primary"
    }

    func listEvents(calendarId: String, timeMin: Date?, timeMax: Date?, query: String?, singleEvents: Bool, maxResults: Int, orderBy: String) async throws -> [GCalEvent] {
        guard let db = AppDatabase.shared.withLock({ $0 }) else { return [] }
        let rows: [DemoCalendarEventRow] = try await db.dbPool.read { conn in
            var sql = "SELECT * FROM demoCalendarEvent WHERE accountId = ?"
            var args: [DatabaseValueConvertible] = [self.accountId]
            if let timeMin {
                sql += " AND endMs >= ?"
                args.append(Int64(timeMin.timeIntervalSince1970 * 1000))
            }
            if let timeMax {
                sql += " AND startMs <= ?"
                args.append(Int64(timeMax.timeIntervalSince1970 * 1000))
            }
            sql += " ORDER BY startMs ASC LIMIT ?"
            args.append(maxResults > 0 ? maxResults : 250)
            return try DemoCalendarEventRow.fetchAll(conn, sql: sql, arguments: StatementArguments(args))
        }
        let qLower = query?.lowercased()
        let filtered = qLower.map { q in
            rows.filter {
                $0.title.lowercased().contains(q) ||
                ($0.location?.lowercased().contains(q) ?? false) ||
                ($0.description?.lowercased().contains(q) ?? false)
            }
        } ?? rows
        return filtered.map(Self.toGCalEvent)
    }

    func getEvent(calendarId: String, eventId: String) async throws -> GCalEvent {
        guard let db = AppDatabase.shared.withLock({ $0 }) else {
            throw DemoError.notInDemo
        }
        let row: DemoCalendarEventRow? = try await db.dbPool.read { conn in
            try DemoCalendarEventRow
                .fetchOne(conn, sql: "SELECT * FROM demoCalendarEvent WHERE id = ?", arguments: [eventId])
        }
        guard let row else {
            throw DemoError.startFailed("event not found")
        }
        return Self.toGCalEvent(row)
    }

    func createEvent(calendarId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent {
        guard let db = AppDatabase.shared.withLock({ $0 }) else {
            throw DemoError.notInDemo
        }
        let id = event.id ?? "demo-event-\(UUID().uuidString.prefix(12))"
        let (startMs, endMs, allDay) = Self.parseDateInput(event)
        try await db.dbPool.write { conn in
            try conn.execute(sql: """
                INSERT OR REPLACE INTO demoCalendarEvent
                (id, accountId, calendarId, title, location, description, startMs, endMs, allDay, attendeesJSON)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                id,
                self.accountId,
                "primary",
                event.summary ?? "(no title)",
                event.location,
                event.description,
                startMs,
                endMs,
                allDay ? 1 : 0,
                Self.encodeAttendees(event.attendees),
            ])
        }
        return try await getEvent(calendarId: "primary", eventId: id)
    }

    func updateEvent(calendarId: String, eventId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent {
        guard let db = AppDatabase.shared.withLock({ $0 }) else {
            throw DemoError.notInDemo
        }
        let (startMs, endMs, allDay) = Self.parseDateInput(event)
        try await db.dbPool.write { conn in
            try conn.execute(sql: """
                UPDATE demoCalendarEvent
                SET title = ?, location = ?, description = ?, startMs = ?, endMs = ?, allDay = ?, attendeesJSON = ?
                WHERE id = ?
            """, arguments: [
                event.summary ?? "(no title)",
                event.location,
                event.description,
                startMs,
                endMs,
                allDay ? 1 : 0,
                Self.encodeAttendees(event.attendees),
                eventId,
            ])
        }
        return try await getEvent(calendarId: "primary", eventId: eventId)
    }

    func deleteEvent(calendarId: String, eventId: String, sendUpdates: String) async throws {
        guard let db = AppDatabase.shared.withLock({ $0 }) else { return }
        try await db.dbPool.write { conn in
            try conn.execute(sql: "DELETE FROM demoCalendarEvent WHERE id = ?", arguments: [eventId])
        }
    }

    // MARK: - Helpers

    private static func toGCalEvent(_ row: DemoCalendarEventRow) -> GCalEvent {
        let start = Date(timeIntervalSince1970: TimeInterval(row.startMs) / 1000)
        let end = Date(timeIntervalSince1970: TimeInterval(row.endMs) / 1000)
        let isAllDay = row.allDay != 0
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")

        let startDT: GCalDateTime
        let endDT: GCalDateTime
        if isAllDay {
            startDT = GCalDateTime(dateTime: nil, date: dayFormatter.string(from: start), timeZone: nil)
            endDT = GCalDateTime(dateTime: nil, date: dayFormatter.string(from: end), timeZone: nil)
        } else {
            startDT = GCalDateTime(dateTime: formatter.string(from: start), date: nil, timeZone: nil)
            endDT = GCalDateTime(dateTime: formatter.string(from: end), date: nil, timeZone: nil)
        }
        return GCalEvent(
            id: row.id,
            summary: row.title,
            location: row.location,
            description: row.description,
            start: startDT,
            end: endDT,
            attendees: nil,
            organizer: nil,
            recurrence: nil,
            transparency: nil,
            status: "confirmed",
            htmlLink: nil,
            created: nil,
            updated: nil
        )
    }

    private static func parseDateInput(_ input: GCalEventInput) -> (startMs: Int64, endMs: Int64, allDay: Bool) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")

        var startDate = Date()
        var endDate = Date().addingTimeInterval(3600)
        var allDay = false

        if let s = input.startDateTime, let parsed = formatter.date(from: s) ?? ISO8601DateFormatter().date(from: s) {
            startDate = parsed
        } else if let s = input.startDate, let parsed = dayFormatter.date(from: s) {
            startDate = parsed
            allDay = true
        }
        if let e = input.endDateTime, let parsed = formatter.date(from: e) ?? ISO8601DateFormatter().date(from: e) {
            endDate = parsed
        } else if let e = input.endDate, let parsed = dayFormatter.date(from: e) {
            endDate = parsed
            allDay = true
        }
        return (Int64(startDate.timeIntervalSince1970 * 1000), Int64(endDate.timeIntervalSince1970 * 1000), allDay)
    }

    private static func encodeAttendees(_ attendees: [(email: String, name: String?)]?) -> String? {
        guard let attendees, !attendees.isEmpty else { return nil }
        let array = attendees.map { att -> [String: String] in
            var d = ["email": att.email]
            if let n = att.name { d["name"] = n }
            return d
        }
        return (try? JSONSerialization.data(withJSONObject: array)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
