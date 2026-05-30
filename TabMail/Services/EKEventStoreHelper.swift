/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

@preconcurrency import EventKit

/// Stateless helper wrapping `EKEventStore` CRUD operations for calendar agent tools.
/// Uses a shared `EKEventStore` instance (Apple recommends long-lived stores for performance).
/// The enum is inherently `Sendable`.
///
/// Does NOT replace any existing calendar UI — this serves agent tool execution only.
enum EKEventStoreHelper {
    /// UserDefaults key for the user's preferred calendar identifier for new events.
    /// `nil` / empty = use iOS default calendar (system `defaultCalendarForNewEvents`).
    static let preferredCalendarKey = "calendar_preferred_calendar_id"

    /// Shared store instance. EKEventStore is thread-safe per Apple docs.
    /// Long-lived instance recommended: "requires a relatively large amount of time to initialize."
    /// Exposed for `EKEventEditViewController` which requires the same store instance.
    nonisolated(unsafe) static let eventStore = EKEventStore()

    /// Internal alias for backward compatibility within this file.
    private static var store: EKEventStore { eventStore }

    /// Trigger EventKit to re-fetch from external sources (e.g. Google Calendar).
    /// Best-effort — call after Google Calendar API mutations so iOS Calendar app stays in sync.
    static func refreshSources() {
        store.refreshSourcesIfNecessary()
    }

    // MARK: - Authorization

    static func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            print("[EKEventStoreHelper] requestAccess failed: \(error)")
            return false
        }
    }

    // MARK: - Query

    /// Search events within a date range, optionally filtering by query string.
    /// Query matches against title, location, notes, organizer name, and attendee names.
    static func searchEvents(
        from startDate: Date,
        to endDate: Date,
        query: String? = nil,
        calendars: [EKCalendar]? = nil
    ) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        var events = store.events(matching: predicate)

        // Optional post-filter by query (AND terms, quoted phrase exact match — matching TB)
        if let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            let (terms, phrase) = parseQuery(query)
            events = events.filter { event in
                let hay = [
                    event.title ?? "",
                    event.location ?? "",
                    event.notes ?? "",
                    event.organizer?.name ?? "",
                    (event.attendees ?? []).map { $0.name ?? "" }.joined(separator: " "),
                ].joined(separator: "\n").lowercased()

                for term in terms {
                    if !hay.contains(term) { return false }
                }
                if let phrase, !hay.contains(phrase) { return false }
                return true
            }
        }

        return events
    }

    /// Fetch a single event by identifier.
    static func fetchEvent(identifier: String) -> EKEvent? {
        store.event(withIdentifier: identifier)
    }

    /// List all user calendars that support events.
    static func listCalendars() -> [EKCalendar] {
        store.calendars(for: .event)
    }

    /// Get the default calendar for new events.
    static func defaultCalendar() -> EKCalendar? {
        store.defaultCalendarForNewEvents
    }

    // MARK: - ICS Invite → EKEvent

    /// Create an EKEvent from a parsed ICS invite (for "Add to Calendar" flow).
    /// The event is NOT saved — caller should present it in `EKEventEditViewController`.
    static func eventFromInvite(_ invite: ICSBuilder.ParsedInvite) -> EKEvent {
        let event = newEvent()
        event.title = invite.title
        event.startDate = invite.startDate ?? Date()
        event.isAllDay = invite.isAllDay
        if let end = invite.endDate {
            event.endDate = end
        } else if invite.isAllDay {
            event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: event.startDate)!
        } else {
            event.endDate = Calendar.current.date(byAdding: .hour, value: 1, to: event.startDate)!
        }
        if let location = invite.location, !location.isEmpty {
            event.location = location
        }
        if let desc = invite.description, !desc.isEmpty {
            event.notes = desc
        }
        event.calendar = calendar(withIdentifier: nil)
        return event
    }

    // MARK: - Create / Update / Delete

    static func saveEvent(_ event: EKEvent, span: EKSpan = .thisEvent) throws {
        try store.save(event, span: span, commit: true)
    }

    static func removeEvent(_ event: EKEvent, span: EKSpan = .thisEvent) throws {
        try store.remove(event, span: span, commit: true)
    }

    /// Create a new EKEvent attached to the store. Caller must configure and then call `saveEvent`.
    static func newEvent() -> EKEvent {
        EKEvent(eventStore: store)
    }

    /// Find a calendar by identifier, falling back to user preference, then system default.
    static func calendar(withIdentifier id: String?) -> EKCalendar? {
        if let id, !id.isEmpty {
            return store.calendar(withIdentifier: id)
        }
        // Check user's preferred calendar from settings
        if let preferred = UserDefaults.standard.string(forKey: preferredCalendarKey),
           !preferred.isEmpty,
           let cal = store.calendar(withIdentifier: preferred) {
            return cal
        }
        return defaultCalendar()
    }

    // MARK: - Formatting

    /// Format an event's time range as "HH:mm - HH:mm" (matching TB output).
    static func formatTimeRange(_ event: EKEvent) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "\(fmt.string(from: event.startDate)) - \(fmt.string(from: event.endDate))"
    }

    /// Format a date as naive ISO (no timezone offset), matching TB's `toNaiveIso()`.
    static func toNaiveISO(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = .current
        return fmt.string(from: date)
    }

    /// Format a date as naive ISO (no timezone offset) in the specified timezone.
    static func toNaiveISO(_ date: Date, timeZone: TimeZone) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = timeZone
        return fmt.string(from: date)
    }

    /// Format a date as a day key "YYYY-MM-DD" in local timezone.
    static func dayKey(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        return fmt.string(from: date)
    }

    /// Format a date as a day key "YYYY-MM-DD" in the specified timezone.
    static func dayKey(_ date: Date, timeZone: TimeZone) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = timeZone
        return fmt.string(from: date)
    }

    /// Format a date as a pretty day header (e.g., "Monday, January 15, 2025").
    static func prettyDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .full
        fmt.timeZone = .current
        return fmt.string(from: date)
    }

    /// Format a date as a pretty day header in the specified timezone.
    static func prettyDate(_ date: Date, timeZone: TimeZone) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .full
        fmt.timeZone = timeZone
        return fmt.string(from: date)
    }

    /// Parse a naive ISO date string (no timezone) into a Date in the user's local timezone.
    static func parseNaiveISO(_ iso: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = .current
        if let date = fmt.date(from: iso) { return date }
        // Try date-only format
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: iso)
    }

    /// Parse a naive ISO date string (no timezone) into a Date in the specified timezone.
    static func parseNaiveISO(_ iso: String, timeZone: TimeZone) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = timeZone
        if let date = fmt.date(from: iso) { return date }
        // Try date-only format
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: iso)
    }

    // MARK: - Calendar Enumeration

    struct CalendarInfo: Identifiable, Sendable {
        let id: String           // EKCalendar.calendarIdentifier
        let title: String        // EKCalendar.title
        let sourceName: String   // EKSource.title (e.g. "iCloud", "Gmail")
        let color: CGColor
        let isDefault: Bool
    }

    /// List all writable calendars that support events, grouped info for settings UI.
    static func availableCalendars() -> [CalendarInfo] {
        let defaultId = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .map { cal in
                CalendarInfo(
                    id: cal.calendarIdentifier,
                    title: cal.title,
                    sourceName: cal.source.title,
                    color: cal.cgColor,
                    isDefault: cal.calendarIdentifier == defaultId
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Query Parsing

    /// Parse query into AND terms and optional exact phrase (matching TB).
    private static func parseQuery(_ raw: String) -> ([String], String?) {
        var phrase: String?
        if let match = raw.range(of: #""([^"]+)""#, options: .regularExpression) {
            let quoted = raw[match]
            let inner = quoted.dropFirst().dropLast()
            phrase = String(inner).lowercased()
        }
        let remainder = raw.replacingOccurrences(of: #""[^"]+""#, with: " ", options: .regularExpression)
        let terms = remainder.split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return (terms, phrase)
    }
}
