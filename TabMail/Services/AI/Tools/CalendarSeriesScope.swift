/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// How an edit of a repeating event reaches its series, on every provider. The edit tool applies it
/// before its confirmation card and the calendar queue again before the write, with the same
/// decision both times.
///
/// - **An occurrence is named by where it is now.** A `recurrence_id` is always the occurrence's
///   current start, as the read tools show it (`start_iso`); nothing here rewrites it to the
///   occurrence's place in the series. `read` resolves the occurrence once, through the provider's
///   own lookup (`CalendarProvider.occurrence`), into an event that carries both of its times:
///   `start`, where it is now, and `originalStartTime`, its place in the series.
/// - **An edit of every occurrence (`edit_scope` "all") changes the series**, whichever of its
///   occurrences the event id names (#560). The listings give an occurrence its own id on Google,
///   Outlook and CalDAV, and the series is the one its `recurringEventId` names.
/// - **A time change of every occurrence goes where Google Calendar takes it** (#559), as the
///   Thunderbird add-on's `routeSeriesTimeChange` does. Named from the series' first occurrence, the
///   whole series moves. Named from a later one, a new time of day on the date it is on now is the
///   whole series' new time, on the first occurrence's date; a new date is a change of that
///   occurrence and the ones after it (`this_and_following`). With no occurrence named and a new
///   date other than the series' own, the assistant is told to ask the user which they mean. The
///   series is never moved by the distance from a later occurrence.
/// - **A change of an occurrence and the following ones named at the series' first occurrence is a
///   change of the whole series**, as in Google Calendar; one named before it is refused.
/// - **A series whose rule names its days is not moved to another date without its new rule**
///   (`dayMoveRefusal`).
///
/// First or later is judged on the occurrence's place in the series (`originalStartTime`); a
/// date or a time change, and the move back to the first occurrence's date, on where it is now
/// (`start`). A timed series' dates are read in its own zone (`GCalEvent.seriesZone`), the zone its
/// rule repeats in; a timed series whose zone is not known is taken to move to another date, the
/// side that splits or asks, never a wrong write. An all-day series' places are dates, as every
/// provider gives them, and need no zone.
enum CalendarSeriesScope {

    /// The event an edit names, the series it belongs to, and the occurrence it names.
    struct Named: Sendable {
        /// The id the edit names.
        let eventId: String
        /// The event that id names.
        let event: GCalEvent
        /// The series' id: the event's own id when it is no occurrence (a one-off event, or a series
        /// named by its own id).
        let seriesId: String
        /// The series, or the event itself when it is no occurrence.
        let series: GCalEvent
        /// The occurrence the edit names, as the provider's lookup found it
        /// (`CalendarProvider.occurrence`); nil when it names none (a one-off event, or a series
        /// named by its own id with no `recurrence_id`).
        let occurrence: GCalEvent?
        /// The series already ends with the cap a split at the edit's `recurrence_id` writes
        /// (`CalendarProvider.isOwnSplitCap`): the queue's retry of a split interrupted after its
        /// cap. `occurrence` is nil then, as the cap ended the series before it.
        var afterOwnSplitCap = false

        var isOccurrence: Bool { seriesId != eventId }
    }

    /// Read what an edit names: `eventId`, its series when it names an occurrence, and
    /// the occurrence it names, by its `recurrence_id` (read in `zone`) or, for an occurrence id
    /// given without one, by the start it has now. The occurrence is found by the provider's own
    /// lookup, the one its one-occurrence edit and split make; so what the lookup refuses is refused
    /// here, before the card, for every scope alike. A split at an occurrence moved from its place is
    /// not looked for here: `route` may make it an edit of the whole series (the first occurrence),
    /// and the split itself throws at one (#563).
    ///
    /// `splitting`: the queue is about to write a split (`this_and_following`) at `recurrenceId`.
    /// When the series already ends with this split's own cap (`CalendarProvider.isOwnSplitCap`),
    /// an earlier attempt wrote the cap and was interrupted before the rest, and the occurrence is
    /// not looked for: the cap ended the series before it, so the lookup would report it not found
    /// and the drain would retire the split half done. `Named.afterOwnSplitCap` says so, with no
    /// occurrence, and the queue goes on to `splitSeries`, which finishes it. The edit tool passes
    /// false: a split asked for at a series that already ends there has nothing to split.
    ///
    /// Throws, with nothing written: what the provider throws (its not-found error when no
    /// occurrence starts at `recurrence_id`, `notSupported` for an occurrence id that names another
    /// occurrence than `recurrence_id`, an ambiguous or malformed one, and what CalDAV's own check
    /// refuses; a deleted occurrence is its not-found), and `notSupported` for an occurrence whose
    /// start can't be read. A failed read is thrown, never replaced: the edit tool refuses, or the
    /// drain classifies it.
    static func read(
        eventId: String, recurrenceId: String?, calendarId: String, zone: TimeZone,
        splitting: Bool, provider: any CalendarProvider
    ) async throws -> Named {
        let event = try await provider.getEvent(calendarId: calendarId, eventId: eventId)
        return try await read(
            event: event, eventId: eventId, recurrenceId: recurrenceId,
            calendarId: calendarId, zone: zone, splitting: splitting, provider: provider)
    }

    /// `read`, with `eventId` already read (`event`): the edit tool reads it on its own, to tell a
    /// wrong event id from an occurrence it does not name.
    static func read(
        event: GCalEvent, eventId: String, recurrenceId: String?, calendarId: String, zone: TimeZone,
        splitting: Bool, provider: any CalendarProvider
    ) async throws -> Named {
        if let seriesId = event.recurringEventId, !seriesId.isEmpty, seriesId != eventId {
            guard let named = recurrenceId ?? shownStart(of: event, zone: zone) else {
                throw CalendarProviderError.notSupported(
                    "the start of the occurrence this event_id names can't be read; pass recurrence_id (the occurrence's start_iso as calendar_event_read shows it)")
            }
            let series = try await provider.getEvent(calendarId: calendarId, eventId: seriesId)
            // Before the lookup: past this split's cap the occurrence may read as deleted.
            if splitting, provider.isOwnSplitCap(of: series, at: named, zone: zone) {
                return Named(eventId: eventId, event: event, seriesId: seriesId, series: series, occurrence: nil, afterOwnSplitCap: true)
            }
            // A deleted occurrence, which Google and CalDAV read by its id with status `cancelled`,
            // is the lookup's not-found: no provider's lookup finds one.
            let occurrence = try await provider.occurrence(
                calendarId: calendarId, eventId: eventId, recurrenceId: named, recurrenceIdZone: zone)
            return Named(eventId: eventId, event: event, seriesId: seriesId, series: series, occurrence: occurrence)
        }
        guard let recurrenceId, !(event.recurrence ?? []).isEmpty else {
            return Named(eventId: eventId, event: event, seriesId: eventId, series: event, occurrence: nil)
        }
        if splitting, provider.isOwnSplitCap(of: event, at: recurrenceId, zone: zone) {
            return Named(eventId: eventId, event: event, seriesId: eventId, series: event, occurrence: nil, afterOwnSplitCap: true)
        }
        let occurrence = try await provider.occurrence(
            calendarId: calendarId, eventId: eventId, recurrenceId: recurrenceId, recurrenceIdZone: zone)
        return Named(eventId: eventId, event: event, seriesId: eventId, series: event, occurrence: occurrence)
    }

    /// What the assistant is told when a `recurrence_id` names none of a series' occurrences: none
    /// starts there now, or it was deleted. Nil: the occurrence an event id names without one.
    static func namesNoOccurrence(_ recurrenceId: String?) -> String {
        let named = recurrenceId.map { "recurrence_id '\($0)' names" } ?? "the event_id names"
        return "\(named) none of this repeating event's occurrences (none starts there, or it was deleted), so nothing was changed; look the occurrence up with calendar_read or calendar_search, and pass the event_id listed for it with its start_iso as recurrence_id"
    }

    /// An edit as `route` sends it: the scope it is written in, its arguments (with `edit_scope`,
    /// `recurrence_id`, `start_iso` and `end_iso` as `route` set them), and the event id it is
    /// queued with. Given to `route` again, it routes to itself.
    struct Routed: Sendable {
        let scope: String
        let args: [String: JSONValue]
        let eventId: String

        var recurrenceId: String? { CalendarToolHelpers.stringArgOpt(args, "recurrence_id") }
    }

    /// Where an edit of a repeating series goes, its naive times read in `zone` (the edit's
    /// `timezone`). An edit that is not of a repeating series, a `this_only` edit, and an "all" edit
    /// that gives no new start or end go as given.
    ///
    /// A `this_and_following` edit at the series' first occurrence is an edit of the whole series,
    /// routed as an "all" edit from the first occurrence; one before it is refused; at a later one
    /// it goes as given.
    ///
    /// An "all" edit that gives a new start or end goes by the occurrence it names (`Named.occurrence`):
    /// - the series' first occurrence: the whole series. A new date is a plain move, the occurrence
    ///   kept as its `recurrence_id`; a new time on the date the occurrence is on now is the series'
    ///   new time on its own date (`movedToFirst`).
    /// - a later occurrence and a new start on another date than the one it is on now:
    ///   `this_and_following` at that occurrence;
    /// - a later occurrence and a new start on its date (or no new start): the whole series, its new
    ///   start and end moved back to the first occurrence's date with their times of day kept
    ///   (`movedToFirst`), queued with the series' id and no `recurrence_id`, so the queue's pass
    ///   reads it as a move of the series on its own date;
    /// - none, and the new start (the new end, for an edit giving only an end) on the date of the
    ///   series' own start (end): as given;
    /// - none, and another date: refused, telling the assistant to ask the user which occurrences
    ///   they mean.
    ///
    /// Refused, with nothing written: an occurrence before the series' first, one whose place in
    /// the series can't be read, and a series whose start can't be read.
    static func route(_ args: [String: JSONValue], scope: String, named: Named, zone: TimeZone) throws -> Routed {
        let asGiven = Routed(scope: scope, args: args, eventId: named.eventId)
        let series = named.series
        guard !(series.recurrence ?? []).isEmpty else { return asGiven }
        switch scope {
        case "this_and_following":
            // A missing `recurrence_id` is refused by the caller's scope switch.
            guard let occurrence = named.occurrence else { return asGiven }
            let first = try firstPlace(series)
            let slot = try slotPlace(occurrence)
            switch try order(slot, first) {
            case .orderedAscending: throw beforeFirst(shown(slot, zone: zone), first: first, zone: zone)
            case .orderedSame: return try routeEvery(args, named: named, occurrence: occurrence, first: first, zone: zone)
            case .orderedDescending: return asGiven
            }
        case "all":
            guard movesTime(args) else { return asGiven }
            let first = try firstPlace(series)
            guard let occurrence = named.occurrence else {
                // No occurrence named: the new start, or the new end of an edit giving only an end, on
                // the series' own date is a move of the series; another date is a question for the user.
                let start = CalendarToolHelpers.stringArgOpt(args, "start_iso")
                let given = start ?? CalendarToolHelpers.stringArgOpt(args, "end_iso") ?? ""
                guard let own = place(start != nil ? series.start : series.end),
                      sameDate(given, as: own, series: series, zone: zone) else {
                    throw CalendarProviderError.notSupported(
                        "the new time of this repeating event is on another date than its first occurrence (\(shown(first, zone: zone))); " + askWhichOccurrences)
                }
                return asGiven
            }
            return try routeEvery(args, named: named, occurrence: occurrence, first: first, zone: zone)
        default:
            return asGiven
        }
    }

    /// An edit of every occurrence named at `occurrence` (see `route`).
    private static func routeEvery(
        _ args: [String: JSONValue], named: Named, occurrence: GCalEvent, first: Place, zone: TimeZone
    ) throws -> Routed {
        let series = named.series
        let slot = try slotPlace(occurrence)
        let isFirst: Bool
        switch try order(slot, first) {
        case .orderedAscending: throw beforeFirst(shown(slot, zone: zone), first: first, zone: zone)
        case .orderedSame: isFirst = true
        case .orderedDescending: isFirst = false
        }
        let now = try currentPlace(occurrence)
        let recurrenceId = CalendarToolHelpers.stringArgOpt(args, "recurrence_id") ?? shown(now, zone: zone)
        guard movesTime(args) else {
            return routed(args, scope: "all", recurrenceId: recurrenceId, eventId: named.eventId)
        }
        // From the first occurrence the whole series; from a later one a split there.
        func fromHere() -> Routed {
            routed(args, scope: isFirst ? "all" : "this_and_following", recurrenceId: recurrenceId, eventId: named.eventId)
        }
        if let start = CalendarToolHelpers.stringArgOpt(args, "start_iso"),
           !sameDate(start, as: now, series: series, zone: zone) {
            return fromHere()
        }
        // A new time of day on the date the occurrence is on now: the whole series' new time, on its
        // own date. When the days between can't be counted, the cautious side: a split from a later
        // occurrence, the edit as given from the first.
        guard let moved = movedToFirst(args, from: now, to: first, series: series, zone: zone) else {
            return fromHere()
        }
        var written = moved
        written["edit_scope"] = .string("all")
        written.removeValue(forKey: "recurrence_id")
        return Routed(scope: "all", args: written, eventId: named.seriesId)
    }

    /// What the assistant is told when an edit of every occurrence gives a new date but names no
    /// occurrence. The words of the Thunderbird add-on's `ASK_WHICH_OCCURRENCES`; both scopes it names
    /// take a `recurrence_id`.
    static let askWhichOccurrences =
        "ask the user whether they mean just that date, or that date and every later one; then pass recurrence_id (the occurrence's start_iso as calendar_event_read shows it) with edit_scope 'this_only' or 'this_and_following'"

    /// Why the queue does not write an edit of every occurrence that `route` makes a
    /// `this_and_following` edit. The edit tool makes it one before its card, so one reaches the
    /// queue as "all" only when the series changed after the card. It is not changed there: the
    /// user confirmed a change of every occurrence.
    static func laterOccurrenceRefusal(_ recurrenceId: String) -> String {
        "the edit names a later occurrence (\(recurrenceId)) of a repeating event and moves it to another date: a move from it on is edit_scope 'this_and_following' with recurrence_id '\(recurrenceId)'; a move of every occurrence names the first one"
    }

    /// 🚨 **THE ONE PLACE A MOVE OF A SERIES TO ANOTHER DAY IS DECIDED: a series whose rule names its
    /// days is not moved to another date unless the edit gives its new rule.**
    ///
    /// Every provider keeps the stored rule when a series' start moves, so a series repeating on
    /// named days moved to another date would go on repeating on the old days, and its first
    /// occurrence would be the only one on the new day. Returns why the edit is refused, or nil.
    ///
    /// Refused: an edit in scope "all" or `this_and_following` whose new start is on another date
    /// than what it moves (an "all" edit: the series' own start; a `this_and_following` edit: the
    /// start its occurrence has now), of a series whose RRULE has a part in `namedDayParts`, giving
    /// no `recurrence` that `buildGCalEventInput` writes in its place. A move to another time on the
    /// same date, an end alone, `this_only`, and a rule that names no days (its days follow the
    /// start) pass.
    ///
    /// The dates are the series' own, in its zone (`GCalEvent.seriesZone`), where its rule repeats.
    /// When they can't be told (a timed series whose zone is not known), the move is refused.
    ///
    /// Called before the confirmation card (`CalendarEventEditTool`) and again before the write
    /// (`AccountManagerCalendarQueue`), on every provider, with what `read` returns and the edit as
    /// `route` sent it. Not on the queue's retry of a split after its own cap
    /// (`Named.afterOwnSplitCap`): the attempt that wrote the cap passed it, and the occurrence it
    /// compares is past the cap.
    static func dayMoveRefusal(_ args: [String: JSONValue], named: Named, scope: String, zone: TimeZone) -> String? {
        guard scope == "all" || scope == "this_and_following",
              let start = CalendarToolHelpers.stringArgOpt(args, "start_iso"),
              !givesRule(args) else { return nil }
        let series = named.series
        let days = namedDays(series)
        guard !days.isEmpty else { return nil }
        let instead = "give the new repeat rule (recurrence) with the move, or change just that date (edit_scope 'this_only' with recurrence_id)"
        let moved = scope == "this_and_following" ? named.occurrence?.start : series.start
        guard let from = place(moved),
              let dates = dates(of: start, and: from, series: series, zone: zone) else {
            return "this repeating event repeats on named days (\(days.joined(separator: ";"))), and it can't be told whether the new start (\(start)) keeps its date, as its own time zone is not known; \(instead)"
        }
        guard dates.given != dates.place else { return nil }
        return "this repeating event repeats on named days (\(days.joined(separator: ";"))), so moving it from \(dates.place) to \(dates.given) would leave its days unchanged; \(instead)"
    }

    /// The RRULE parts that name the days or dates a series repeats on. A rule with none of them
    /// repeats on its start's day, so its days move with the start.
    static let namedDayParts: Set<String> = ["BYDAY", "BYMONTHDAY", "BYYEARDAY", "BYWEEKNO", "BYMONTH", "BYSETPOS"]

    /// Where an occurrence is, or is placed in its series, as `route` compares it.
    private enum Place: Equatable {
        /// An all-day series' occurrence: its date (`yyyy-MM-dd`).
        case date(String)
        /// A timed series' occurrence: its start.
        case instant(Date)
    }

    /// The series' first occurrence: its start.
    private static func firstPlace(_ series: GCalEvent) throws -> Place {
        guard let first = place(series.start) else {
            throw CalendarProviderError.notSupported(
                "the start of this repeating event can't be read, so it is not known which of its occurrences the new time is for")
        }
        return first
    }

    /// The occurrence's place in the series (`originalStartTime`).
    private static func slotPlace(_ occurrence: GCalEvent) throws -> Place {
        guard let slot = place(occurrence.originalStartTime) else {
            throw CalendarProviderError.notSupported(
                "the place in its series of the occurrence named can't be read, so it is not known whether it is the series' first; pass recurrence_id as the start_iso of the occurrence calendar_event_read shows")
        }
        return slot
    }

    /// Where the occurrence is now (`start`).
    private static func currentPlace(_ occurrence: GCalEvent) throws -> Place {
        guard let now = place(occurrence.start) else {
            throw CalendarProviderError.notSupported(
                "the start of the occurrence named can't be read; pass recurrence_id as the start_iso of the occurrence calendar_event_read shows")
        }
        return now
    }

    /// A start, or an occurrence's `originalStartTime`, as a place; nil when there is none or it
    /// can't be read. An all-day one is a date, as every provider gives it (Outlook's place read in
    /// the series' own zone, `ExchangeCalendarProvider.allDayOccurrence`), so no zone is needed to
    /// date it. A time given where the series is all-day can't be compared with its dates (`order`).
    private static func place(_ value: GCalDateTime?) -> Place? {
        if let date = value?.date { return .date(String(date.prefix(10))) }
        guard let dateTime = value?.dateTime, let instant = Date.fromISO8601(dateTime) else { return nil }
        return .instant(instant)
    }

    /// Whether `place` is before, at or after `first`. Thrown when the two can't be compared (one a
    /// date and the other a time, in a series that changed kind).
    private static func order(_ place: Place, _ first: Place) throws -> ComparisonResult {
        switch (place, first) {
        case (.date(let a), .date(let b)): return a.compare(b)
        case (.instant(let a), .instant(let b)): return a.compare(b)
        default:
            throw CalendarProviderError.notSupported(
                "the occurrence named can't be compared with this repeating event's first occurrence (one is all-day, the other timed); pass recurrence_id as the start_iso of an occurrence calendar_event_read shows")
        }
    }

    private static func beforeFirst(_ named: String, first: Place, zone: TimeZone) -> Error {
        CalendarProviderError.notSupported(
            "\(named) is before the first occurrence of this repeating event (\(shown(first, zone: zone))), so it names none of its occurrences; pass recurrence_id as the start_iso of the occurrence calendar_event_read shows")
    }

    /// A place as a `recurrence_id` gives it, and as the read tools show a start
    /// (`formatDetailedEvent`): a date as `allDayNaiveISO`, a time as its wall time in `zone`.
    private static func shown(_ place: Place, zone: TimeZone) -> String {
        switch place {
        case .date(let date): return CalendarToolHelpers.allDayNaiveISO(date)
        case .instant(let instant): return EKEventStoreHelper.toNaiveISO(instant, timeZone: zone)
        }
    }

    /// The start `event` has now, as the read tools show it in `zone` (`formatDetailedEvent`); nil
    /// when it can't be read.
    private static func shownStart(of event: GCalEvent, zone: TimeZone) -> String? {
        if let date = event.start?.date { return CalendarToolHelpers.allDayNaiveISO(date) }
        guard let dateTime = event.start?.dateTime, let instant = Date.fromISO8601(dateTime) else { return nil }
        return EKEventStoreHelper.toNaiveISO(instant, timeZone: zone)
    }

    /// The date of `place` and of `given` (a naive start, read in `zone`) in the series' own zone.
    /// Nil when they can't be told: a timed series whose zone is not known, or a start that can't be
    /// read.
    private static func dates(of given: String, and place: Place, series: GCalEvent, zone: TimeZone)
        -> (place: String, given: String)? {
        switch place {
        case .date(let date): return (date, String(given.prefix(10)))
        case .instant(let at):
            guard let own = series.seriesZone, let new = instant(given, zone: zone) else { return nil }
            return (EKEventStoreHelper.dayKey(at, timeZone: own), EKEventStoreHelper.dayKey(new, timeZone: own))
        }
    }

    /// Whether `given` is on `place`'s date in the series' own zone; false when it can't be told.
    private static func sameDate(_ given: String, as place: Place, series: GCalEvent, zone: TimeZone) -> Bool {
        dates(of: given, and: place, series: series, zone: zone).map { $0.place == $0.given } ?? false
    }

    /// `args` with `start_iso` and `end_iso` moved back from `occurrence`'s date to `first`'s by
    /// whole calendar days in the series' own zone, each keeping its time of day there: a new time
    /// named from a later occurrence, made the whole series'. Calendar days, never multiples of
    /// 24 hours, so a time of day kept across a change to or from summer time names the series'
    /// own start, which the write then leaves as it is. Nil when the days between can't be counted
    /// (a timed series whose zone is not known) or a time can't be read.
    private static func movedToFirst(_ args: [String: JSONValue], from occurrence: Place, to first: Place,
                                     series: GCalEvent, zone: TimeZone) -> [String: JSONValue]? {
        var calendar = Calendar(identifier: .gregorian)
        let days: Int?
        switch (occurrence, first) {
        case (.date(let a), .date(let b)):
            calendar.timeZone = .gmt
            guard let from = EKEventStoreHelper.parseNaiveISO(a, timeZone: .gmt),
                  let to = EKEventStoreHelper.parseNaiveISO(b, timeZone: .gmt) else { return nil }
            days = calendar.dateComponents([.day], from: to, to: from).day
        case (.instant(let a), .instant(let b)):
            guard let own = series.seriesZone else { return nil }
            calendar.timeZone = own
            days = calendar.dateComponents([.day], from: calendar.startOfDay(for: b), to: calendar.startOfDay(for: a)).day
        default:
            return nil
        }
        guard let days else { return nil }
        var moved = args
        for key in ["start_iso", "end_iso"] {
            guard let value = CalendarToolHelpers.stringArgOpt(args, key) else { continue }
            if series.start?.date != nil {
                guard let date = EKEventStoreHelper.parseNaiveISO(String(value.prefix(10)), timeZone: .gmt),
                      let back = calendar.date(byAdding: .day, value: -days, to: date) else { return nil }
                moved[key] = .string(EKEventStoreHelper.dayKey(back, timeZone: .gmt) + value.dropFirst(10))
            } else {
                guard let at = instant(value, zone: zone),
                      let back = calendar.date(byAdding: .day, value: -days, to: at) else { return nil }
                moved[key] = .string(EKEventStoreHelper.toNaiveISO(back, timeZone: zone))
            }
        }
        return moved
    }

    /// `args` written in `scope` at `recurrenceId`, queued with `eventId`.
    private static func routed(_ args: [String: JSONValue], scope: String, recurrenceId: String, eventId: String) -> Routed {
        var written = args
        written["edit_scope"] = .string(scope)
        written["recurrence_id"] = .string(recurrenceId)
        return Routed(scope: scope, args: written, eventId: eventId)
    }

    /// A start, end or `recurrence_id` as an instant, read as the tools read one
    /// (`CalendarToolHelpers.toolInstant`): one spelled with an offset as it says, a naive one in
    /// `zone`.
    private static func instant(_ value: String, zone: TimeZone) -> Date? {
        CalendarToolHelpers.toolInstant(value, timeZone: zone)
    }

    /// The parts of `series`' RRULE in `namedDayParts`, as the rule writes them (`BYDAY=MO,WE`).
    private static func namedDays(_ series: GCalEvent) -> [String] {
        (series.recurrence ?? []).flatMap { line -> [String] in
            guard line.uppercased().hasPrefix("RRULE:") else { return [] }
            return line.dropFirst("RRULE:".count).split(separator: ";").map(String.init).filter { part in
                namedDayParts.contains(part.split(separator: "=", maxSplits: 1).first.map { $0.uppercased() } ?? "")
            }
        }
    }

    /// Whether the edit gives a rule `buildGCalEventInput` writes: a `recurrence` with a `freq` it
    /// accepts. It writes none for any other.
    private static func givesRule(_ args: [String: JSONValue]) -> Bool {
        guard case .dictionary(let rec) = args["recurrence"], case .string(let freq) = rec["freq"] else { return false }
        return CalendarToolHelpers.validatedRRuleFreq(freq) != nil
    }

    /// Whether the edit gives a new start or end.
    private static func movesTime(_ args: [String: JSONValue]) -> Bool {
        CalendarToolHelpers.stringArgOpt(args, "start_iso") != nil || CalendarToolHelpers.stringArgOpt(args, "end_iso") != nil
    }
}
