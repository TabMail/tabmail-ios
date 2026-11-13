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
/// - **A series whose rule names its days moves them with a move to another date** (`dayMove`), as
///   Google Calendar does.
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
        /// The series, or the event itself when it is no occurrence. Nil when the edit names an
        /// occurrence in a scope that does not use its series (`usesSeries`, a `this_only` edit):
        /// `read` does not read it, and a CalDAV resource holding only changed occurrences (an
        /// invitation to single occurrences) has none (#720). Never the occurrence in its place:
        /// an edit of every occurrence or a split gets it from `readSeries()`, which throws when it
        /// was not read.
        let series: GCalEvent?
        /// The occurrence the edit names, as the provider's lookup found it
        /// (`CalendarProvider.occurrence`); nil when it names none (a one-off event, or a series
        /// named by its own id with no `recurrence_id`).
        let occurrence: GCalEvent?

        var isOccurrence: Bool { seriesId != eventId }

        /// The series an edit of every occurrence or a split is routed by and written to. Thrown
        /// when it was not read, so such an edit never goes on to the event it names.
        func readSeries() throws -> GCalEvent {
            guard let series else { throw CalendarProviderError.notSupported(seriesNotRead) }
            return series
        }
    }

    /// Why an edit of every occurrence or a split is not made when the series was not read
    /// (`Named.series`). `read` reads it for every scope that uses it, so this is not reached.
    static let seriesNotRead =
        "the repeating event this occurrence belongs to was not read, so it can't be changed as a whole or split from here"

    /// Whether an edit in `scope` uses the series of the occurrence it names: an edit of every
    /// occurrence ("all") and a split (`this_and_following`) are routed by it and may write it. A
    /// `this_only` edit writes the occurrence alone, through the provider's own one-occurrence
    /// lookup and write, and reads nothing of the series.
    static func usesSeries(_ scope: String) -> Bool {
        scope == "all" || scope == "this_and_following"
    }

    /// Read what an edit names: `eventId`, its series when it names an occurrence, and
    /// the occurrence it names, by its `recurrence_id` (read in `zone`) or, for an occurrence id
    /// given without one, by the start it has now. The occurrence is found by the provider's own
    /// lookup, the one its one-occurrence edit and split make; so what the lookup refuses is refused
    /// here, before the card, for every scope alike. A split at an occurrence moved from its place is
    /// not looked for here: `route` may make it an edit of the whole series (the first occurrence),
    /// and the split itself throws at one (#563).
    ///
    /// `scope`: the scope the edit is given. The series of an occurrence is read only for a scope
    /// that uses it (`usesSeries`); a `this_only` edit reads the event and the provider's lookup
    /// only, and its `Named.series` is nil (#720).
    ///
    /// A split interrupted after its new part was written does not come here: the queue finishes
    /// it from its `SplitRecord` (#601).
    ///
    /// Throws, with nothing written: what the provider throws (its not-found error when no
    /// occurrence starts at `recurrence_id`, `notSupported` for an occurrence id that names another
    /// occurrence than `recurrence_id`, an ambiguous or malformed one, and what CalDAV's own check
    /// refuses; a deleted occurrence is its not-found), and `notSupported` for an occurrence whose
    /// start can't be read. A failed read is thrown, never replaced: the edit tool refuses, or the
    /// drain classifies it.
    static func read(
        eventId: String, recurrenceId: String?, scope: String, calendarId: String, zone: TimeZone,
        provider: any CalendarProvider
    ) async throws -> Named {
        let event = try await provider.getEvent(calendarId: calendarId, eventId: eventId)
        return try await read(
            event: event, eventId: eventId, recurrenceId: recurrenceId, scope: scope,
            calendarId: calendarId, zone: zone, provider: provider)
    }

    /// `read`, with `eventId` already read (`event`): the edit tool reads it on its own, to tell a
    /// wrong event id from an occurrence it does not name.
    static func read(
        event: GCalEvent, eventId: String, recurrenceId: String?, scope: String, calendarId: String, zone: TimeZone,
        provider: any CalendarProvider
    ) async throws -> Named {
        if let seriesId = event.recurringEventId, !seriesId.isEmpty, seriesId != eventId {
            // An occurrence id given without a `recurrence_id` names the occurrence by the start it
            // has now, as the provider read it: in the device's zone, the zone a CalDAV floating time
            // (no zone) is read in (`ICSParser`), so it is shown and looked up in that zone. Shown in
            // `zone` instead, a floating occurrence's wall clock is another one whenever `zone` is not
            // the device's (a queued edit drained after the device's zone changed, #753), and the
            // lookup, which compares floating times by wall clock in the zone it is given (#761),
            // finds none (the drain then retires the confirmed edit as not found) or another. A
            // time with a zone names the same instant in either zone.
            let namedZone = recurrenceId == nil ? TimeZone.current : zone
            guard let named = recurrenceId ?? shownStart(of: event, zone: namedZone) else {
                throw CalendarProviderError.notSupported(
                    "the start of the occurrence this event_id names can't be read; pass recurrence_id (the occurrence's start_iso as calendar_event_read shows it)")
            }
            // A `this_only` edit does not use the series: only the occurrence, by the provider's own
            // lookup (the one its write makes), which refuses a `recurrence_id` naming another
            // occurrence or none before the card. A CalDAV resource holding only changed
            // occurrences has no series to read (#720).
            guard usesSeries(scope) else {
                let occurrence = try await provider.occurrence(
                    calendarId: calendarId, eventId: eventId, recurrenceId: named, recurrenceIdZone: namedZone)
                return Named(eventId: eventId, event: event, seriesId: seriesId, series: nil, occurrence: occurrence)
            }
            // The series, for an edit of every occurrence or a split. Where the calendar holds no
            // series (a CalDAV resource holding only changed occurrences), the provider refuses this
            // read with its final reason, before the card and at the drain alike.
            let series = try await provider.getEvent(calendarId: calendarId, eventId: seriesId)
            // A deleted occurrence, which Google and CalDAV read by its id with status `cancelled`,
            // is the lookup's not-found: no provider's lookup finds one.
            let occurrence = try await provider.occurrence(
                calendarId: calendarId, eventId: eventId, recurrenceId: named, recurrenceIdZone: namedZone)
            return Named(eventId: eventId, event: event, seriesId: seriesId, series: series, occurrence: occurrence)
        }
        guard let recurrenceId, !(event.recurrence ?? []).isEmpty else {
            return Named(eventId: eventId, event: event, seriesId: eventId, series: event, occurrence: nil)
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
    /// the series can't be read, a series whose start can't be read, and an edit of every
    /// occurrence or a split whose series was not read (`Named.readSeries`): never as given.
    ///
    /// `recurrenceIdZone`: the zone the edit's `recurrence_id` is read in, the device's, where the read
    /// tools print it, whatever `zone` is (#794); a `recurrence_id` `route` names is shown in it.
    static func route(_ args: [String: JSONValue], scope: String, named: Named, zone: TimeZone, recurrenceIdZone: TimeZone) throws -> Routed {
        let asGiven = Routed(scope: scope, args: args, eventId: named.eventId)
        guard usesSeries(scope) else { return asGiven }
        let series = try named.readSeries()
        guard !(series.recurrence ?? []).isEmpty else { return asGiven }
        switch scope {
        case "this_and_following":
            // A missing `recurrence_id` is refused by the caller's scope switch.
            guard let occurrence = named.occurrence else { return asGiven }
            let first = try firstPlace(series)
            let slot = try slotPlace(occurrence)
            switch try order(slot, first) {
            case .orderedAscending: throw beforeFirst(shown(slot, zone: zone), first: first, zone: zone)
            case .orderedSame: return try routeEvery(args, named: named, series: series, occurrence: occurrence, first: first, zone: zone, recurrenceIdZone: recurrenceIdZone)
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
            return try routeEvery(args, named: named, series: series, occurrence: occurrence, first: first, zone: zone, recurrenceIdZone: recurrenceIdZone)
        default:
            return asGiven
        }
    }

    /// An edit of every occurrence of `series` named at `occurrence` (see `route`).
    private static func routeEvery(
        _ args: [String: JSONValue], named: Named, series: GCalEvent, occurrence: GCalEvent, first: Place, zone: TimeZone,
        recurrenceIdZone: TimeZone
    ) throws -> Routed {
        let slot = try slotPlace(occurrence)
        let isFirst: Bool
        switch try order(slot, first) {
        case .orderedAscending: throw beforeFirst(shown(slot, zone: zone), first: first, zone: zone)
        case .orderedSame: isFirst = true
        case .orderedDescending: isFirst = false
        }
        let now = try currentPlace(occurrence)
        let recurrenceId = CalendarToolHelpers.stringArgOpt(args, "recurrence_id") ?? shown(now, zone: recurrenceIdZone)
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

    /// Where a delete of an occurrence and every later one (`delete_scope` "this_and_following")
    /// cuts the series, as Google Calendar and the Thunderbird add-on cut it.
    struct FollowingDelete: Sendable, Equatable {
        /// The occurrence named is the series' first: every occurrence goes, a delete of the whole
        /// series.
        let isFirst: Bool
        /// The occurrence's place in the series (`originalStartTime`), as a `recurrence_id` gives
        /// it in the zone `followingDelete` was given: the series is ended just before it
        /// (`CalendarProvider.endSeries`). An occurrence moved from its place is cut at the place,
        /// so it goes with the later ones and every earlier one stays.
        let cut: String
        /// For an occurrence moved from its place: where it is now and its place, as the card
        /// shows them ("from X, originally Y"); nil for one at its place.
        let moved: Moved?

        struct Moved: Sendable, Equatable {
            let now: String
            let originally: String
        }
    }

    /// Where a delete of `named`'s occurrence and every later one cuts its series. Judged on the
    /// occurrence's place in the series (`originalStartTime`), as `route` judges a split: at the
    /// series' first occurrence it is a delete of the whole series (`isFirst`); before it, refused;
    /// at a later one, the series is ended just before that place (`cut`). An occurrence moved from
    /// its place is cut at the place, not where it is now. The cut, and the card's times, are
    /// shown in `recurrenceIdZone` (the device's, where the read tools print a start); an
    /// occurrence at its place named by `recurrenceId` is cut at that `recurrence_id`, as a split
    /// at it is.
    ///
    /// Throws `notSupported`, with nothing written: no occurrence named, a series not read
    /// (`Named.readSeries`), an occurrence before the series' first, and a place or start that
    /// can't be read or compared.
    static func followingDelete(named: Named, recurrenceId: String?, recurrenceIdZone: TimeZone) throws -> FollowingDelete {
        let series = try named.readSeries()
        guard let occurrence = named.occurrence else {
            throw CalendarProviderError.notSupported(
                "this delete names no occurrence of the repeating event; pass recurrence_id (the occurrence's start_iso as calendar_event_read shows it)")
        }
        let first = try firstPlace(series)
        let slot = try slotPlace(occurrence)
        let isFirst: Bool
        switch try order(slot, first) {
        case .orderedAscending: throw beforeFirst(shown(slot, zone: recurrenceIdZone), first: first, zone: recurrenceIdZone)
        case .orderedSame: isFirst = true
        case .orderedDescending: isFirst = false
        }
        let now = try currentPlace(occurrence)
        guard now != slot else {
            return FollowingDelete(isFirst: isFirst, cut: recurrenceId ?? shown(slot, zone: recurrenceIdZone), moved: nil)
        }
        return FollowingDelete(
            isFirst: isFirst, cut: shown(slot, zone: recurrenceIdZone),
            moved: .init(now: cardShown(now, zone: recurrenceIdZone), originally: cardShown(slot, zone: recurrenceIdZone)))
    }

    /// A place as the delete card shows it: a date alone for an all-day one, a time as its wall time
    /// in `zone`.
    private static func cardShown(_ place: Place, zone: TimeZone) -> String {
        switch place {
        case .date(let date): return date
        case .instant(let instant): return EKEventStoreHelper.toNaiveISO(instant, timeZone: zone)
        }
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
    /// days moves them with it**, as Google Calendar does (`RecurrenceDayShift`).
    ///
    /// Every provider keeps the stored rule when a series' start moves, so a series repeating on
    /// named days moved to another date would go on repeating on the old days. Returns the move
    /// the write carries (`GCalEventInput.ruleDayMove`): each provider turns the days of the rule it
    /// writes by it (the whole series' rule, or the new part's rule of a split, its end carried as
    /// the split carries it). Nil when there is nothing to turn: a scope other than "all" or
    /// `this_and_following`, no new start, a new start on the same date as what it moves (an "all"
    /// edit: the series' own start; a `this_and_following` edit: the start its occurrence has
    /// now), a rule that names no days (its days follow the start), or an edit that gives its own
    /// rule (`recurrence`), which is written as given.
    ///
    /// The dates are the series' own, in its zone (`GCalEvent.seriesZone`), where its rule repeats.
    ///
    /// Throws `notSupported`, with nothing written: when the dates can't be told (a timed series
    /// whose zone is not known), and when the rule names its days in a way a move can't carry
    /// (`RecurrenceDayShift.shifted`).
    ///
    /// Called before the confirmation card (`CalendarEventEditTool`) and again before the write
    /// (`AccountManagerCalendarQueue`), on every provider, with what `read` returns and the edit as
    /// `route` sent it. A split's move is counted from its occurrence's place in the series
    /// (`originalStartTime`). A split the queue finishes from its `SplitRecord` (#601) is not
    /// checked again: the attempt that wrote its new part, its rule turned, passed it.
    static func dayMove(_ args: [String: JSONValue], named: Named, scope: String, zone: TimeZone) throws -> RecurrenceDayShift.Move? {
        guard scope == "all" || scope == "this_and_following",
              let start = CalendarToolHelpers.stringArgOpt(args, "start_iso"),
              !givesRule(args) else { return nil }
        // Both scopes read the series (`usesSeries`); one not read is refused, never passed.
        let series = try named.readSeries()
        let rules = (series.recurrence ?? []).filter { $0.uppercased().hasPrefix("RRULE:") }
        guard rules.contains(where: RecurrenceDayShift.namesDays) else { return nil }
        // Whether the date changes is judged on where the occurrence is now; how far the days turn,
        // from its place in the series (its scheduled slot), the frame the new part's rule repeats
        // in. An "all" edit moves the series from its own start.
        let now: Place?
        let slot: Place?
        if scope == "this_and_following" {
            // A missing `recurrence_id` is refused by the caller's scope switch, as in `route`.
            guard let occurrence = named.occurrence else { return nil }
            now = place(occurrence.start)
            slot = place(occurrence.originalStartTime) ?? place(occurrence.start)
        } else {
            now = place(series.start)
            slot = now
        }
        let unknownZone = CalendarProviderError.notSupported(
            "this repeating event repeats on named days (\(namedDays(series).joined(separator: ";"))), and it can't be told whether the new start (\(start)) keeps its date, as its own time zone is not known; give the new repeat rule (recurrence) with the move, or change just that date (edit_scope 'this_only' with recurrence_id)")
        guard let now, let current = dates(of: start, and: now, series: series, zone: zone) else { throw unknownZone }
        guard current.given != current.place else { return nil }
        guard let slot, let dates = dates(of: start, and: slot, series: series, zone: zone),
              let fromDay = RecurrenceTail.Day(iso: dates.place),
              let toDay = RecurrenceTail.Day(iso: dates.given) else { throw unknownZone }
        let move = RecurrenceDayShift.Move(from: fromDay, to: toDay)
        guard move.days != 0 else { return nil }
        for rule in rules { _ = try RecurrenceDayShift.shifted(rule, by: move) }
        return move
    }

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
                RecurrenceDayShift.namedDayParts.contains(part.split(separator: "=", maxSplits: 1).first.map { $0.uppercased() } ?? "")
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
