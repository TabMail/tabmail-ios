/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Shared helpers for calendar tools — date range resolution, output formatting,
/// and argument parsing. Matches TB addon's calendar output format.
enum CalendarToolHelpers {

    // MARK: - Timezone Resolution

    /// Resolve timezone from tool arguments. Returns specified IANA timezone or device default.
    static func resolveTimeZone(_ arguments: [String: JSONValue]) -> TimeZone {
        if let tzId = stringArgOpt(arguments, "timezone"),
           let tz = TimeZone(identifier: tzId) {
            return tz
        }
        return .current
    }

    // MARK: - Date Range Resolution (matching TB's resolveDateRange)

    /// Resolve from_date/to_date arguments into a (startDate, endDate) tuple.
    /// Uses the specified timezone for interpreting naive ISO strings.
    ///
    /// **Date-only `to_date` is inclusive.** If the LLM passes
    /// `to_date=2026-04-30` (no time component), the user means "include
    /// events on April 30", so we bump the upper bound to start-of-next-day
    /// (May 1 00:00 in the resolved tz) — Google's `events.list` returns
    /// events with `start < timeMax`, so this makes April 30 events visible.
    /// A full datetime `to_date=2026-04-30T15:00:00` is used verbatim.
    /// Mirrors `EmailSearchTool`'s date-only handling.
    static func resolveDateRange(_ arguments: [String: JSONValue]) -> (Date, Date) {
        let fromArg = stringArg(arguments, "from_date")
        let toArg = stringArg(arguments, "to_date")
        let tz = resolveTimeZone(arguments)
        // When the caller supplied a non-empty `query` but no explicit dates,
        // they are searching by name and almost certainly want to find the
        // event regardless of when it occurs. A 1-day window is wrong here:
        // it caused the LLM to miss the second half of a split series and
        // tell the user "this event ends" when in fact a successor series
        // existed for later occurrences. Widen to past-30d through next-365d
        // for name searches; the no-query (overview) path keeps the original
        // tight window so an unsolicited summary doesn't return a year of
        // entries.
        let queryArg = stringArg(arguments, "query")
        let hasQuery = !queryArg.isEmpty

        let startDate: Date
        if !fromArg.isEmpty, let parsed = EKEventStoreHelper.parseNaiveISO(fromArg, timeZone: tz) {
            startDate = parsed
        } else {
            var cal = Calendar.current
            cal.timeZone = tz
            let today = cal.startOfDay(for: Date())
            startDate = hasQuery ? today.addingTimeInterval(-30 * 86400) : today
        }

        let endDate: Date
        if !toArg.isEmpty, let parsed = EKEventStoreHelper.parseNaiveISO(toArg, timeZone: tz) {
            // Date-only "YYYY-MM-DD" → inclusive end-of-day (+1 day).
            let isDateOnly = (toArg.count == 10 && !toArg.contains("T"))
            endDate = isDateOnly ? parsed.addingTimeInterval(86400) : parsed
        } else if hasQuery {
            // Name search default: 1 year forward from today (not from
            // startDate, which may be 30d in the past). Anchor on today so
            // back/forward windows are symmetric around "now".
            var cal = Calendar.current
            cal.timeZone = tz
            let today = cal.startOfDay(for: Date())
            endDate = today.addingTimeInterval(365 * 86400)
        } else {
            endDate = startDate.addingTimeInterval(86400)
        }

        return (startDate, endDate)
    }

    // MARK: - Argument Helpers

    static func stringArg(_ args: [String: JSONValue], _ key: String) -> String {
        if case .string(let s) = args[key] { return s.trimmingCharacters(in: .whitespaces) }
        return ""
    }

    static func stringArgOpt(_ args: [String: JSONValue], _ key: String) -> String? {
        if case .string(let s) = args[key] { return s.trimmingCharacters(in: .whitespaces) }
        return nil
    }

    static func boolArg(_ args: [String: JSONValue], _ key: String) -> Bool? {
        if case .bool(let b) = args[key] { return b }
        return nil
    }

    // MARK: - Multi-Calendar Fetch

    /// Fetch events from ALL calendars across ALL accounts.
    /// Returns event tuples with account/calendar provenance + the parent
    /// calendar's accessRole, plus a calendar name lookup. accessRole is the
    /// Google-style string ("owner" / "writer" / "reader" / "freeBusyReader");
    /// nil for providers that don't model the concept (CalDAV/Exchange).
    /// Error resilient: logs and skips failing accounts/calendars without
    /// blocking others. `maxResults` is per-calendar (CalendarSearchTool=250,
    /// CalendarReadTool=2500).
    static func fetchEventsFromAllCalendars(
        backends: [(provider: any CalendarProvider, account: Account)],
        timeMin: Date?,
        timeMax: Date?,
        query: String?,
        singleEvents: Bool = true,
        maxResults: Int = 250,
        orderBy: String = "startTime"
    ) async -> (events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)], calendarNames: [String: String]) {
        var allEvents: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = []
        var calendarNames: [String: String] = [:]

        await withTaskGroup(of: ([(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)], [String: String]).self) { group in
            for backend in backends {
                let provider = backend.provider
                let accountId = backend.account.id
                group.addTask {
                    var events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] = []
                    var names: [String: String] = [:]
                    print("[CalendarToolHelpers] account=\(accountId) provider=\(type(of: provider)) listCalendars starting")
                    do {
                        let allCalendars = try await provider.listCalendars()
                        print("[CalendarToolHelpers] account=\(accountId) listCalendars returned \(allCalendars.count)")
                        for cal in allCalendars {
                            print("[CalendarToolHelpers]   account=\(accountId) cal id='\(cal.id)' name='\(cal.summary ?? "?")' primary=\(cal.primary == true) selected=\(cal.selected.map(String.init(describing:)) ?? "nil") accessRole=\(cal.accessRole ?? "?")")
                        }
                        // Resolve visibility per calendar: user override (from
                        // `CalendarVisibilityStore`) wins, otherwise we honor
                        // the provider's `selected` flag. Google's UI flag is
                        // normalized in `GoogleCalendarProvider.listCalendars`
                        // (nil → false). CalDAV/Exchange leave nil → visible.
                        let calendars = allCalendars.filter { cal in
                            if !CalendarVisibilityStore.isVisible(cal, accountId: accountId) {
                                let why = CalendarVisibilityStore.reason(cal, accountId: accountId).rawValue
                                print("[CalendarToolHelpers] SKIP calendar id='\(cal.id)' name='\(cal.summary ?? "?")' acct=\(accountId) reason=\(why)")
                                return false
                            }
                            return true
                        }
                        print("[CalendarToolHelpers] account=\(accountId) iterating \(calendars.count) calendars (after selected filter)")
                        for calendar in calendars {
                            let nameKey = CompoundEventId.make(accountId: accountId, eventId: calendar.id)
                            names[nameKey] = calendar.summary ?? calendar.id
                            do {
                                let calEvents = try await provider.listEvents(
                                    calendarId: calendar.id,
                                    timeMin: timeMin,
                                    timeMax: timeMax,
                                    query: query,
                                    singleEvents: singleEvents,
                                    maxResults: maxResults,
                                    orderBy: orderBy
                                )
                                let emptyCount = calEvents.filter { ($0.summary?.isEmpty ?? true) }.count
                                print("[CalendarToolHelpers] account=\(accountId) calendar='\(calendar.summary ?? "?")' (id=\(calendar.id)) → \(calEvents.count) events (\(emptyCount) empty-title)")
                                for event in calEvents {
                                    if (event.summary?.isEmpty ?? true) {
                                        print("[CalendarToolHelpers]   EMPTY id=\(event.id ?? "?") on calendar='\(calendar.summary ?? "?")' accessRole=\(calendar.accessRole ?? "?") attendees=\(event.attendees?.count ?? 0) loc='\(event.location ?? "")' status=\(event.status ?? "?") eventType=\(event.eventType ?? "?") iCalUID=\(event.iCalUID ?? "?") visibility=\(event.visibility ?? "?")")
                                    }
                                    events.append((event: event, accountId: accountId, calendarId: calendar.id, accessRole: calendar.accessRole))
                                }
                            } catch {
                                print("[CalendarToolHelpers] listEvents FAILED for calendar '\(calendar.id)' acct=\(accountId): \(error)")
                            }
                        }
                    } catch {
                        print("[CalendarToolHelpers] listCalendars FAILED for account=\(accountId): \(error)")
                    }
                    return (events, names)
                }
            }
            for await (events, names) in group {
                allEvents.append(contentsOf: events)
                calendarNames.merge(names) { _, new in new }
            }
        }

        allEvents.sort { ($0.event.startDate ?? .distantPast) < ($1.event.startDate ?? .distantPast) }
        print("[CalendarToolHelpers] fetchEventsFromAllCalendars: \(allEvents.count) events from \(backends.count) accounts, \(calendarNames.count) calendars")
        return (allEvents, calendarNames)
    }

    /// For each unique `recurringEventId` referenced by the supplied events,
    /// fetch the master via the matching provider (deduped) and return a map
    /// `recurringEventId → first RRULE string`. This is the enrichment that
    /// makes `formatGroupedSummary` parity-with-TB for Google's
    /// `singleEvents=true` path: expanded instances arrive with an empty
    /// `recurrence` array, but the LLM needs the rule (UNTIL/COUNT) to
    /// distinguish a capped predecessor series from an open-ended successor.
    ///
    /// Returns an empty map if no events reference a recurring master.
    /// Fetches are concurrent (one per unique master) and best-effort —
    /// any individual failure logs a warning and is silently omitted.
    static func resolveMasterRecurrence(
        events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)],
        backends: [(provider: any CalendarProvider, account: Account)]
    ) async -> [String: String] {
        // Index providers by account id for O(1) lookup.
        let providerByAccount = Dictionary(uniqueKeysWithValues: backends.map { ($0.account.id, $0.provider) })

        // Collect (account, calendar, masterId) triples — deduped on masterId
        // alone is wrong (the same id could nominally exist in two accounts),
        // so we key on (account, masterId). Calendar id is needed to address
        // the master via `getEvent(calendarId:eventId:)`.
        struct Key: Hashable { let accountId: String; let masterId: String }
        var keyToCalendarId: [Key: String] = [:]
        for entry in events {
            guard let masterId = entry.event.recurringEventId, !masterId.isEmpty else { continue }
            let key = Key(accountId: entry.accountId, masterId: masterId)
            // First-seen wins. Different occurrences of the same master always
            // share the same calendar, so any one occurrence's calendar id is
            // sufficient.
            if keyToCalendarId[key] == nil {
                keyToCalendarId[key] = entry.calendarId
            }
        }
        if keyToCalendarId.isEmpty { return [:] }

        let pairs = keyToCalendarId.map { ($0.key, $0.value) }
        var out: [String: String] = [:]

        await withTaskGroup(of: (String, String?).self) { group in
            for (key, calendarId) in pairs {
                guard let provider = providerByAccount[key.accountId] else { continue }
                group.addTask {
                    do {
                        let master = try await provider.getEvent(calendarId: calendarId, eventId: key.masterId)
                        let rrule = master.recurrence?.first(where: { $0.uppercased().hasPrefix("RRULE:") }) ?? ""
                        return (key.masterId, rrule.isEmpty ? nil : rrule)
                    } catch {
                        print("[CalendarToolHelpers] resolveMasterRecurrence: getEvent failed acct=\(key.accountId) master=\(key.masterId): \(error)")
                        return (key.masterId, nil)
                    }
                }
            }
            for await (masterId, rrule) in group {
                if let rrule { out[masterId] = rrule }
            }
        }
        print("[CalendarToolHelpers] resolveMasterRecurrence: enriched \(out.count) master(s) from \(keyToCalendarId.count) unique reference(s)")
        return out
    }

    // MARK: - GCalEvent Formatting (Google Calendar API)

    /// Free/busy access role marker: events from a `freeBusyReader` calendar
    /// have all details server-stripped (no title, no description, no
    /// attendees). They mean "this person is busy here" and we render them
    /// distinctively so the agent doesn't try to act on them like real
    /// titled events.
    static let freeBusyAccessRole = "freeBusyReader"

    /// Cleanup helper for the free/busy "Source: …" label. Email-style
    /// calendar ids ("alice@example.com") get reduced to the local-part.
    /// Falls through verbatim for non-email shapes ("primary", group ids).
    static func freeBusyDisplayName(calendarName: String?, calendarId: String) -> String {
        let raw = (calendarName?.isEmpty == false ? calendarName! : calendarId)
        if let at = raw.firstIndex(of: "@") {
            return String(raw[..<at])
        }
        return raw
    }

    /// Format event tuples into grouped output by date. Emits compound event_id (accountId:rawEventId).
    /// Events from `freeBusyReader` calendars render as "Busy — <calname>"
    /// instead of the title (Google strips titles on those calendars).
    static func formatGroupedSummary(
        _ events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)],
        calendarNames: [String: String] = [:],
        timeZone: TimeZone? = nil,
        masterRRuleById: [String: String] = [:]
    ) -> String {
        struct DayEntry {
            let dayKey: String
            let prettyDate: String
            let line: String
            let sortDate: Date
        }

        let tz = timeZone ?? .current
        var dayGroups: [String: [DayEntry]] = [:]
        var dayOrder: [String] = []
        var seenDays = Set<String>()

        for entry in events {
            guard let start = entry.event.startDate else { continue }
            let dk = EKEventStoreHelper.dayKey(start, timeZone: tz)

            let isFreeBusy = (entry.accessRole == Self.freeBusyAccessRole)
            // Suppress recur/free marks on freeBusy rows: the title is already
            // "Busy — …", and Google strips both fields server-side, but if
            // partial data ever leaks through we don't want "Busy — X (↻) [free]".
            // Surface the RRULE on recurring entries so the LLM can see UNTIL/COUNT
            // and reason about edit_scope. Two sources, in priority:
            //   1. `entry.event.recurrence` — populated when the API returned the
            //      master directly (e.g. singleEvents=false, or the event is non-
            //      recurring's master with its own recurrence).
            //   2. `masterRRuleById[recurringEventId]` — populated by the caller
            //      via `resolveMasterRecurrence` for instances Google expanded
            //      out of a recurring master. Without this, every line for the
            //      "Weekly sync" series would carry only `(↻)` — no UNTIL info.
            // Match TB parity: TB's bridge always has access to the master's RRULE
            // because Lightning's recurrenceInfo lives on the parent item.
            let recurMark: String = {
                if isFreeBusy { return "" }
                if let recArr = entry.event.recurrence, !recArr.isEmpty,
                   let rrule = recArr.first(where: { $0.uppercased().hasPrefix("RRULE:") }) {
                    return " (↻ \(rrule))"
                }
                if let masterId = entry.event.recurringEventId,
                   let rrule = masterRRuleById[masterId], !rrule.isEmpty {
                    return " (↻ \(rrule))"
                }
                // Fallback: instance from a recurring master we couldn't enrich,
                // or some other recurrence path. Show the marker so the LLM at
                // least knows the entry is part of a series.
                if entry.event.recurringEventId != nil { return " (↻)" }
                if let recArr = entry.event.recurrence, !recArr.isEmpty { return " (↻)" }
                return ""
            }()
            let busyMark = (!isFreeBusy && entry.event.transparency == "transparent") ? " [free]" : ""

            let timeRange: String
            if entry.event.isAllDay {
                timeRange = "All day"
            } else if let endDate = entry.event.endDate {
                let fmt = DateFormatter()
                fmt.dateFormat = "HH:mm"
                fmt.timeZone = tz
                timeRange = "\(fmt.string(from: start)) - \(fmt.string(from: endDate))"
            } else {
                timeRange = EKEventStoreHelper.toNaiveISO(start, timeZone: tz)
            }

            let title: String
            if isFreeBusy {
                let calNameKey = CompoundEventId.make(accountId: entry.accountId, eventId: entry.calendarId)
                let display = Self.freeBusyDisplayName(calendarName: calendarNames[calNameKey], calendarId: entry.calendarId)
                title = "Busy — \(display)"
            } else {
                title = (entry.event.summary ?? "").isEmpty ? "(No title)" : entry.event.summary!
            }
            let rawEventId = entry.event.id ?? ""
            let eventIdOutput = entry.accountId.isEmpty ? rawEventId : CompoundEventId.make(accountId: entry.accountId, eventId: rawEventId)
            let line = "\(timeRange): \(title)\(recurMark)\(busyMark)\tevent_id: \(eventIdOutput)"

            let dayEntry = DayEntry(
                dayKey: dk,
                prettyDate: EKEventStoreHelper.prettyDate(start, timeZone: tz),
                line: line,
                sortDate: start
            )
            dayGroups[dk, default: []].append(dayEntry)

            if !seenDays.contains(dk) {
                seenDays.insert(dk)
                dayOrder.append(dk)
            }
        }

        dayOrder.sort()

        var output: [String] = []
        for dk in dayOrder {
            guard var entries = dayGroups[dk], !entries.isEmpty else { continue }
            entries.sort { $0.sortDate < $1.sortDate }
            var lines: [String] = []
            lines.append("date: \(entries[0].prettyDate)")
            lines.append("timezone: \(tz.identifier)")
            for entry in entries {
                lines.append(entry.line)
            }
            output.append(lines.joined(separator: "\n"))
        }

        return output.joined(separator: "\n\n")
    }

    /// Legacy overload for callers that don't yet have account/calendar context.
    static func formatGroupedSummary(gcalEvents: [GCalEvent], timeZone: TimeZone? = nil) -> String {
        let tuples: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] =
            gcalEvents.map { (event: $0, accountId: "", calendarId: "", accessRole: nil) }
        return formatGroupedSummary(tuples, timeZone: timeZone)
    }

    /// Render a provider `DATE` value (`yyyy-MM-dd`, RFC 5545 §3.3.4) as the
    /// naive ISO shape the tool output uses, **without any zone conversion**.
    ///
    /// A calendar DATE has no timezone. Parsing one into a `Date` fixes it to
    /// midnight in whatever zone the parser was configured with, and rendering
    /// that instant in any other zone moves it onto an adjacent day — which is
    /// how an all-day `recurrence_id` comes to name the wrong occurrence. The
    /// provider's own digits are the whole of the value; this only appends the
    /// `T00:00:00` the output shape expects.
    static func allDayNaiveISO(_ providerDate: String) -> String {
        "\(String(providerDate.prefix(10)))T00:00:00"
    }

    /// Format a single GCalEvent with full details (same output as EKEvent version).
    /// `accountId` is used to build compound event_id for translator mapping.
    /// `accessRole` (when "freeBusyReader") swaps the title for "Busy — …" and
    /// suppresses the title-only and details lines that don't exist for those
    /// events. `timeZone` controls which timezone the start_iso/end_iso are
    /// formatted in (nil = device).
    static func formatDetailedEvent(_ event: GCalEvent, accountId: String = "", calendarId: String = "", accessRole: String? = nil, calendarName: String? = nil, timeZone: TimeZone? = nil) -> String {
        let tz = timeZone ?? .current
        var lines: [String] = []
        let eventIdOutput = accountId.isEmpty ? (event.id ?? "") : CompoundEventId.make(accountId: accountId, eventId: event.id ?? "")
        lines.append("event_id: \(eventIdOutput)")
        let isFreeBusy = (accessRole == Self.freeBusyAccessRole)
        if isFreeBusy {
            let display = Self.freeBusyDisplayName(calendarName: calendarName, calendarId: calendarId)
            lines.append("title: Busy — \(display)")
        } else {
            lines.append("title: \((event.summary ?? "").isEmpty ? "(No title)" : event.summary!)")
        }

        // 🚨 AN ALL-DAY DATE IS FRAME-FREE, SO IT IS NEVER RUN THROUGH A ZONE
        // CONVERSION. RFC 5545's `DATE` value type carries no zone at all, and
        // Google/Graph both hand it to us as a bare `yyyy-MM-dd` in `start.date`.
        //
        // ⚠️ UNTIL ROUND 18d THIS BRANCH DID NOT EXIST, and the all-day path ran
        // the same route as the timed one: `GCalEvent.parseDateOnly` parses
        // `start.date` in `.current` — the DEVICE zone — and `toNaiveISO` then
        // re-rendered that instant in `tz`, the resolved DISPLAY zone. Whenever
        // the display zone is west of the device zone the rendered wall clock
        // falls back past midnight and **`start_iso` names the PREVIOUS DAY**.
        // (East shifts the same way once the gap reaches 24 h.)
        //
        // That was not cosmetic. `CalendarEventEditTool` documents `recurrence_id`
        // as "the `start_iso` of the target occurrence", and
        // `RecurrenceOccurrenceResolver`'s rule 3 matches an all-day candidate on
        // its literal `dateOnly` against `recurrenceId.prefix(10)`. So on an
        // all-day DAILY series the shifted date answers to the PRECEDING
        // occurrence, which `updateOccurrence` then `PATCH`es with
        // `sendUpdates: "all"` — a C3 wrong-target mutation whose invitations
        // cannot be recalled. On `splitSeries` it caps the master a day early,
        // and that cap `PUT` is an irreversible-family write with only a
        // compensating rollback.
        //
        // ⚠️ WHAT BREAKS THE OTHER WAY (`MIS-026`). The alternative was to emit a
        // bare `2026-05-20` for an all-day event. It is arguably more honest —
        // there is no time — but it changes the SHAPE of `start_iso` for every
        // all-day event for every user, at the end of an audit train, on a key
        // the tool schemas describe as a naive ISO8601 date-time. Appending
        // `T00:00:00` to the provider's own date is byte-identical to today's
        // output whenever the display zone equals the device zone (the
        // overwhelmingly common case), so only the frame error changes hands.
        // Both forms resolve identically downstream — `prefix(10)` is what every
        // consumer reads (`RecurrenceOccurrenceResolver.select`/`.windowCenter`,
        // `GoogleCalendarProvider.googleUntilString`,
        // `CalDAVProvider.buildNewSeriesInput`) — so the narrower change is the
        // right one.
        if event.isAllDay, let startDay = event.start?.date {
            lines.append("start_iso: \(Self.allDayNaiveISO(startDay))")
            if let endDay = event.end?.date {
                lines.append("end_iso: \(Self.allDayNaiveISO(endDay))")
            } else if let end = event.endDate {
                // Mixed shape (all-day start, timed end). Nothing frame-free to
                // preserve on the end side, so it keeps the display rendering.
                lines.append("end_iso: \(EKEventStoreHelper.toNaiveISO(end, timeZone: tz))")
            }
        } else {
            if let start = event.startDate {
                lines.append("start_iso: \(EKEventStoreHelper.toNaiveISO(start, timeZone: tz))")
            }
            if let end = event.endDate {
                lines.append("end_iso: \(EKEventStoreHelper.toNaiveISO(end, timeZone: tz))")
            }
        }
        // 🚨 `timezone:` NAMES THE ZONE `start_iso`/`end_iso` ARE EXPRESSED IN,
        // AND NOTHING ELSE. It is `tz` — the resolved display zone — because that
        // is what `toNaiveISO` was just handed.
        //
        // ⚠️ ONE STATED EXCEPTION, added with the all-day branch above: for an
        // ALL-DAY event the ISO values are expressed in NO zone, because a
        // calendar DATE has none. `timezone:` then names only the display zone
        // the rest of the output uses, and `all_day: yes` two lines below is what
        // tells the agent the date is absolute. It is deliberately still emitted
        // rather than suppressed: dropping a key for one event shape is a wider
        // output change than the frame fix needs, and the value is harmless
        // because the date it labels is the same in every zone.
        //
        // ⚠️ THIS LINE READ `storedTz.isEmpty ? tz.identifier : storedTz` UNTIL
        // ROUND 18, i.e. it emitted the PROVIDER'S stored zone next to values
        // formatted in the DISPLAY zone whenever the two differed. A Vancouver
        // device reading a Tokyo event therefore produced a self-contradictory
        // pair — a Vancouver wall clock labelled `timezone: Asia/Tokyo` — which
        // names an instant 16 hours from the real one. The old comment
        // ("Either way the agent gets an unambiguous IANA id") was true of the
        // ID and false of the PAIR, which is the whole of the bug.
        //
        // The other three emitters of this key already meant the display zone —
        // `formatGroupedSummary` (`timezone: \(tz.identifier)`),
        // `CalendarEventCreateTool` and `CalendarEventEditTool` (both
        // `timezone: \(resolvedTz.identifier)`) — so this was the odd one out,
        // not the convention.
        //
        // The stored zone is NOT dropped: it is genuinely needed for
        // provider-local wall times and DST reasoning, so it moves to its own
        // key rather than being discarded. Byte-identical to shipped
        // `07a4bb703` before this change; the defect ships today.
        lines.append("timezone: \(tz.identifier)")
        let storedTz = (event.start?.timeZone?.isEmpty == false ? event.start?.timeZone : event.end?.timeZone) ?? ""
        if !storedTz.isEmpty {
            lines.append("event_timezone: \(storedTz)")
        }
        lines.append("all_day: \(event.isAllDay ? "yes" : "no")")
        lines.append("availability: \(event.transparency == "transparent" ? "free" : "busy")")

        // For freeBusy events, suppress every detail block. Google strips them
        // server-side; if any partial data ever leaks through, rendering it
        // under a "Busy" title would mislead the agent.
        if !isFreeBusy {
            if let recurrence = event.recurrence, !recurrence.isEmpty {
                lines.append("recurring: yes")
                lines.append("RRULE: \(recurrence.joined(separator: ";"))")
            }

            if let loc = event.location, !loc.isEmpty {
                lines.append("Location: \(loc)")
            }
            if let org = event.organizer {
                let name = org.displayName ?? ""
                let email = org.email ?? ""
                if !name.isEmpty || !email.isEmpty {
                    let display = !email.isEmpty ? "\(name) <\(email)>" : name
                    lines.append("Organizer: \(display)")
                }
            }

            if let attendees = event.attendees, !attendees.isEmpty {
                lines.append("attendees:")
                for a in attendees {
                    let name = a.displayName ?? ""
                    let email = a.email ?? ""
                    var parts: [String] = []
                    if !name.isEmpty { parts.append(name) }
                    if !email.isEmpty { parts.append("<\(email)>") }
                    let status = (a.responseStatus ?? "").uppercased()
                    let base = parts.joined(separator: " ")
                    lines.append("- \(!status.isEmpty ? "\(base) (\(status))" : base)")
                }
            }

            if let desc = event.description, !desc.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("description: \(desc)")
            }

            if let link = event.htmlLink, !link.isEmpty {
                lines.append("link: \(link)")
            }
        } else {
            lines.append("note: read-only free/busy block — no other details available; cannot be edited or deleted.")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Attendee Parsing for Pills

    /// Build `[EventPillAttendee]` from a provider event's attendee list.
    /// Drops attendees with no email. Used by every event-detail cache site so
    /// the pill popover shows attendees without a separate live re-fetch.
    static func eventPillAttendees(from event: GCalEvent) -> [EventPillAttendee] {
        (event.attendees ?? []).compactMap { att -> EventPillAttendee? in
            guard let email = att.email, !email.isEmpty else { return nil }
            return EventPillAttendee(
                email: email,
                name: att.displayName,
                status: att.responseStatus ?? "needsAction"
            )
        }
    }

    /// Build `[EventPillAttendee]` from raw `calendar_event_create` tool arguments.
    /// Accepts `[{ "email": "...", "name": "..." }]` or `["bare@email.com"]`,
    /// matching `buildGCalEventInput`. A freshly-created event has no responses
    /// yet, so every attendee is `needsAction`. Lets a created event's pill show
    /// its invitees before the create has drained to the provider.
    static func eventPillAttendees(fromArguments arguments: [String: JSONValue]) -> [EventPillAttendee] {
        guard case .array(let arr) = arguments["attendees"] else { return [] }
        return arr.compactMap { item -> EventPillAttendee? in
            if case .dictionary(let dict) = item,
               case .string(let email) = dict["email"], !email.isEmpty {
                let name: String? = if case .string(let n) = dict["name"], !n.isEmpty { n } else { nil }
                return EventPillAttendee(email: email, name: name, status: "needsAction")
            }
            if case .string(let email) = item, !email.isEmpty {
                return EventPillAttendee(email: email, name: nil, status: "needsAction")
            }
            return nil
        }
    }

    // MARK: - Event Detail Caching for Pills

    /// Cache structured event details in ChatIdTranslator for pill popover display.
    /// Called by search/read tools that produce event output with account/calendar context.
    /// `calendarNames` is keyed by compound "accountId:calendarId" to avoid cross-account collision.
    /// For events on `freeBusyReader` calendars, the title is rewritten to
    /// "Busy — <calname>" so a [Event](N) pill tap shows the same label the
    /// agent already saw, instead of "(No title)".
    static func cacheEventDetailsForPills(
        _ events: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)],
        calendarNames: [String: String] = [:],
        translator: any ChatIdTranslating = ChatIdTranslator.shared
    ) async {
        for entry in events {
            guard let eventId = entry.event.id, !eventId.isEmpty else { continue }
            let attendees = eventPillAttendees(from: entry.event)
            let calNameKey = CompoundEventId.make(accountId: entry.accountId, eventId: entry.calendarId)
            let calendarName = calendarNames[calNameKey]
            // Prefer the start.timeZone (Google's authoritative event tz); fall
            // back to end.timeZone if start is missing it. Empty string treated as nil.
            let storedTz: String? = {
                if let tz = entry.event.start?.timeZone, !tz.isEmpty { return tz }
                if let tz = entry.event.end?.timeZone, !tz.isEmpty { return tz }
                return nil
            }()
            let isFreeBusy = (entry.accessRole == Self.freeBusyAccessRole)
            let title: String
            if isFreeBusy {
                let display = freeBusyDisplayName(calendarName: calendarName, calendarId: entry.calendarId)
                title = "Busy — \(display)"
            } else {
                title = (entry.event.summary ?? "").isEmpty ? "(No title)" : entry.event.summary!
            }
            let rrule = (entry.event.recurrence ?? []).first(where: { $0.uppercased().hasPrefix("RRULE:") })
            await translator.cacheEventDetail(
                realId: eventId,
                accountId: entry.accountId,
                calendarId: entry.calendarId,
                calendarName: calendarName,
                title: title,
                startDate: entry.event.startDate,
                endDate: entry.event.endDate,
                isAllDay: entry.event.isAllDay,
                location: isFreeBusy ? nil : entry.event.location,
                notes: isFreeBusy ? nil : entry.event.description,
                attendees: isFreeBusy ? [] : attendees,
                isRecurring: !(entry.event.recurrence ?? []).isEmpty,
                recurrenceRule: isFreeBusy ? nil : rrule,
                availability: entry.event.transparency == "transparent" ? "free" : "busy",
                htmlLink: isFreeBusy ? nil : entry.event.htmlLink,
                eventTimeZone: storedTz
            )
        }
    }

    /// Legacy overload for callers that don't yet have account/calendar context.
    /// Will be removed once all tools are updated to use the tuple-based version.
    static func cacheEventDetailsForPills(
        _ events: [GCalEvent],
        accountId: String = "",
        calendarId: String = "",
        calendarName: String? = nil,
        translator: any ChatIdTranslating = ChatIdTranslator.shared
    ) async {
        let tuples: [(event: GCalEvent, accountId: String, calendarId: String, accessRole: String?)] =
            events.map { (event: $0, accountId: accountId, calendarId: calendarId, accessRole: nil) }
        let calendarNames: [String: String]
        if !accountId.isEmpty, !calendarId.isEmpty, let name = calendarName {
            calendarNames = [CompoundEventId.make(accountId: accountId, eventId: calendarId): name]
        } else {
            calendarNames = [:]
        }
        await cacheEventDetailsForPills(tuples, calendarNames: calendarNames, translator: translator)
    }

    // MARK: - Error Classification

    /// Check if an error indicates "event not found" (404 or equivalent).
    /// Same pattern as AccountManager.isCalendarNotFoundError.
    static func isEventNotFoundError(_ error: Error) -> Bool {
        if case GoogleCalendarError.httpError(404, _) = error { return true }
        if case GoogleCalendarError.eventNotFound = error { return true }
        if case ExchangeCalendarError.httpError(404, _) = error { return true }
        if case ExchangeCalendarError.eventNotFound = error { return true }
        if case CalDAVError.notFound = error { return true }
        return false
    }

    /// Build a `GCalEventInput` from tool arguments.
    static func buildGCalEventInput(_ arguments: [String: JSONValue], isAllDay: Bool?) -> GCalEventInput {
        let resolvedTz = resolveTimeZone(arguments)
        let tz = resolvedTz.identifier
        var input = GCalEventInput()

        if let title = stringArgOpt(arguments, "title") { input.summary = title }
        if let loc = stringArgOpt(arguments, "location") { input.location = loc }
        if let desc = stringArgOpt(arguments, "description") { input.description = desc }

        // Transparency
        if let transparency = stringArgOpt(arguments, "transparency") {
            input.transparency = transparency.lowercased() == "free" ? "transparent" : "opaque"
        }

        // Start
        if let startIso = stringArgOpt(arguments, "start_iso") {
            if isAllDay == true {
                // All-day: use date-only format (YYYY-MM-DD)
                input.startDate = String(startIso.prefix(10))
            } else {
                input.startDateTime = toRFC3339(startIso, timeZone: resolvedTz)
                input.startTimeZone = tz
            }
        }

        // End
        if let endIso = stringArgOpt(arguments, "end_iso") {
            if isAllDay == true {
                input.endDate = String(endIso.prefix(10))
            } else {
                input.endDateTime = toRFC3339(endIso, timeZone: resolvedTz)
                input.endTimeZone = tz
            }
        }

        // Attendees
        if case .array(let arr) = arguments["attendees"] {
            input.attendees = arr.compactMap { item -> (email: String, name: String?)? in
                if case .dictionary(let dict) = item,
                   case .string(let email) = dict["email"], !email.isEmpty {
                    let name: String? = if case .string(let n) = dict["name"], !n.isEmpty { n } else { nil }
                    return (email: email, name: name)
                }
                if case .string(let email) = item, !email.isEmpty {
                    return (email: email, name: nil)
                }
                return nil
            }
        }

        // Recurrence
        //
        // `freq` and `until` are model-supplied strings that get interpolated into a structured RRULE
        // line, which cannot be run through the ICS text escaper (that would corrupt the `;` and `,`
        // separators the rule depends on). FREQ is a closed token set in RFC 5545, so validate it
        // instead of escaping it: an unrecognised value drops the recurrence rather than emitting a
        // rule built from arbitrary text. `GCalEventInputICS.sanitizeICSLine` is the backstop that
        // stops any residue from splitting the line into a second ICS property.
        if case .dictionary(let rec) = arguments["recurrence"],
           case .string(let rawFreq) = rec["freq"],
           let freq = Self.validatedRRuleFreq(rawFreq) {
            var rrule = "RRULE:FREQ=\(freq)"
            if case .int(let n) = rec["interval"], n > 1 { rrule += ";INTERVAL=\(n)" }
            else if case .double(let d) = rec["interval"], Int(d) > 1 { rrule += ";INTERVAL=\(Int(d))" }
            if case .int(let count) = rec["count"] { rrule += ";COUNT=\(count)" }
            else if case .double(let count) = rec["count"] { rrule += ";COUNT=\(Int(count))" }
            else if case .string(let until) = rec["until"],
                    // `allDay:`/`zone:` are not decoration — UNTIL's value type is dictated by the
                    // DTSTART this same builder emits (RFC 5545 §3.3.10), and the naive→UTC conversion
                    // needs the event's zone to name an instant at all. Both are already resolved above
                    // for start/end.
                    let normalizedUntil = Self.validatedRRuleUntil(until, allDay: isAllDay == true, zone: resolvedTz) {
                rrule += ";UNTIL=\(normalizedUntil)"
            }
            input.recurrence = [rrule]
        }

        return input
    }

    /// Could `buildGCalEventInput(arguments:isAllDay:)` emit an `UNTIL` for these arguments?
    ///
    /// **COULD, not WOULD — deliberately WIDER than the producer.** It mirrors the producer's branch
    /// conditions but never asks whether `validatedRRuleUntil` will accept the value, so
    /// `recurrence: {freq: "DAILY", until: "tomorrow"}` answers true while the producer emits no UNTIL
    /// at all — one wasted `getEvent`. Matching the producer EXACTLY needs `isAllDay`, because only its
    /// all-day arm tolerates an invalid TIME portion, and `isAllDay` is what the guarded fetch exists to
    /// discover. Narrowing PARTWAY does not: `validatedRRuleUntil` runs its shape parse and
    /// `rruleUntilDateIsInRange` BEFORE `if allDay`. Nobody has. "Cannot be narrowed" (2026-08-12) was
    /// too strong.
    ///
    /// The `isAllDay` a caller passes decides the UNTIL's VALUE TYPE (RFC 5545 §3.3.10), so an edit
    /// that does not restate `all_day` has to learn it from the event before it can build a legal
    /// rule — and learning it costs a `getEvent`. This predicate is what keeps that fetch off every
    /// other edit: it answers "is an UNTIL actually at stake here?" and nothing else.
    ///
    /// It MIRRORS the recurrence branch of `buildGCalEventInput` deliberately, in the same order and
    /// on the same cases, because a predicate that disagrees with the producer it guards is worse
    /// than no predicate: too narrow and the fetch is skipped on an edit that does emit an UNTIL
    /// (the defect returns, silently); too wide and edits pay a round trip for nothing. The three
    /// conditions are therefore not independent choices — each one is a line of that branch:
    ///
    ///   1. a `recurrence` dictionary with a `freq` `validatedRRuleFreq` accepts — without it the
    ///      producer emits no `RRULE` at all, so there is no UNTIL and no value type to match;
    ///   2. **no numeric `count`** — the producer's `if/else if/else if` chain gives COUNT priority,
    ///      so a rule carrying COUNT never reaches its UNTIL branch. A `count` that is a STRING is
    ///      not one of those cases and does NOT suppress the UNTIL, here or there;
    ///   3. an `until` STRING — the only input the UNTIL branch reads.
    ///
    /// Whether that string survives `validatedRRuleUntil` is not asked (see the headline). A dropped
    /// clause is harmless on the update path and NOT on the split path — see `validatedRRuleUntil` on
    /// what an omitted UNTIL costs a `this_and_following` successor.
    static func recurrenceUntilIsAtStake(_ arguments: [String: JSONValue]) -> Bool {
        guard case .dictionary(let rec) = arguments["recurrence"],
              case .string(let rawFreq) = rec["freq"],
              Self.validatedRRuleFreq(rawFreq) != nil else { return false }
        if case .int = rec["count"] { return false }
        if case .double = rec["count"] { return false }
        if case .string = rec["until"] { return true }
        return false
    }

    /// RFC 5545 `FREQ` is a closed token set. Returns the canonical token, or nil if unrecognised.
    ///
    /// Validated rather than escaped because an RRULE is structured: passing it through the ICS text
    /// escaper would escape the `;` and `,` that separate its own parts. Returning nil drops the
    /// recurrence — the event is still created, just non-recurring, which is recoverable by one user
    /// edit. See `GCalEventInputICS.sanitizeICSLine` for why an unvalidated value is dangerous.
    static func validatedRRuleFreq(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let legal: Set<String> = ["SECONDLY", "MINUTELY", "HOURLY", "DAILY", "WEEKLY", "MONTHLY", "YEARLY"]
        return legal.contains(token) ? token : nil
    }

    /// Normalise a model-supplied RRULE `UNTIL` to the value type RFC 5545 §3.3.10 requires.
    ///
    /// **UNTIL's value type is not free — it is dictated by DTSTART.** §3.3.10: `UNTIL` MUST have the
    /// same value type as `DTSTART`; if `DTSTART` is a date with local time AND A TIME ZONE REFERENCE,
    /// or a date with UTC time, then `UNTIL` MUST be a date with UTC time. A floating `UNTIL` is legal
    /// only against a floating `DTSTART`.
    ///
    /// This function can emit exactly two of the three forms §3.3.10 recognises, selected by `allDay`:
    ///
    ///   - all-day  → bare DATE `YYYYMMDD`
    ///   - timed    → UTC DATE-TIME `YYYYMMDDTHHMMSSZ`
    ///
    /// ⚠️ **`allDay` IS THE CALLER'S CLAIM ABOUT THE DTSTART THIS UPDATE WILL LAND, AND THIS COMMENT
    /// USED TO DESCRIBE THE WRONG PRODUCER.** It said the value type is *"decided by the EVENT, not by
    /// how the model spelled its input"*, and justified that by enumerating what
    /// `GCalEventInputICS.veventLines` emits. That is a claim about the CREATE path, where the same
    /// arguments produce both the DTSTART and the UNTIL, so the two cannot disagree. On the EDIT path
    /// they can and did: `mergePatchIntoICS` leaves the server's `DTSTART` alone when the patch carries
    /// no start, so the value type came from the tool argument while the DTSTART came from the
    /// resource. `AccountManagerCalendarQueue`'s `.edit` case now resolves an absent `all_day` from the
    /// resource itself before calling this, which is what makes the sentence true again — but only for
    /// an ABSENT `all_day`. An `all_day` the model states explicitly is taken at its word, because
    /// stating it is how a timed event is converted to all-day and vice versa; a model that states it
    /// while changing nothing else can still produce a mismatched pair.
    ///
    /// ⚠️ **WHAT `nil` COSTS ON THE SPLIT PATH.** Returning nil drops the `UNTIL` clause while
    /// `buildGCalEventInput` still assigns a non-empty `input.recurrence` (`RRULE:FREQ=…`, plus any
    /// INTERVAL — a numeric COUNT takes an earlier `else if` and cannot coexist with an UNTIL). On
    /// `edit_scope: "this_and_following"`, `CalDAVProvider.buildNewSeriesInput` PREFERS a non-empty
    /// `patch.recurrence` over `stripUntilAndCount(originalRRule)`, so the successor series is written
    /// **unbounded**, carrying only the patch's rule parts — and AFTER the cap `PUT`, which is
    /// irreversible wire operation #6. The 2026-08-12 range check did not create that path but moved
    /// out-of-range dates onto it, from emitted-verbatim (all-day and already-UTC arms) or
    /// silently-rolled (naive arm) to nil. So a NEW rejection here is not free: weigh it against an
    /// unbounded successor, which one further edit can re-cap.
    ///
    /// The third form is the one this function cannot emit at all: `CalDAVProvider.MasterDTStartKind`
    /// models `.floating` (`DTSTART:20260520T170000`, no TZID and no `Z`), and §3.3.10 wants a
    /// FLOATING `UNTIL` against a floating DTSTART. Both outputs above are wrong for that master —
    /// the timed one emits UTC against a floating DTSTART. Not handled, and not claimed to be
    /// impossible: `allDay` is a `Bool`, so there is no value a caller could pass to ask for it.
    ///
    /// ⚠️ TWO WRONG ANSWERS, and this function shipped each of them in turn. Appending `Z` to a naive
    /// value (the original) keeps the value type legal but REINTERPRETS the instant, moving the end of
    /// the series by the user's offset — eight hours early at UTC−8, enough to drop the final
    /// occurrence. Preserving the naive form instead (commit 82a0eda8b, this file's previous version)
    /// fixes the instant and breaks the VALUE TYPE, emitting a floating `UNTIL` against a zoned or UTC
    /// `DTSTART` — which a strict server may reject outright. The invariant has two halves and a fix
    /// that satisfies one by violating the other has not converged; it has moved. Both halves are
    /// checked in `untilIsValidated`.
    ///
    /// The naive → UTC conversion is deliberately NOT
    /// `GoogleCalendarProvider.googleUntilString(beforeNaiveISO:allDay:zone:)` despite the obvious
    /// resemblance: that function subtracts one second (one day for all-day) because it caps a series
    /// STRICTLY BEFORE a split point. `UNTIL` here is the user's own INCLUSIVE end ("repeat until Dec
    /// 31"), so borrowing it would silently shorten every series by a second.
    ///
    /// A date-only input on a timed event is read as the END OF THAT DAY in the event's zone. Reading
    /// it as midnight would drop every occurrence on the day the user named, and returning nil would
    /// leave the series unbounded, which is worse than either.
    ///
    /// Anything unparseable returns nil and the UNTIL clause is omitted — an unbounded recurrence,
    /// deliberately preferred over emitting arbitrary text into a structured rule, and visible and
    /// editable by the user. **"Unparseable" means both halves**: the SHAPE check below, and the
    /// numeric field RANGES in `rruleUntilDateIsInRange` / `rruleUntilTimeIsInRange`. This sentence
    /// claimed both while the function checked only the shape; those two helpers carry the measured
    /// list of out-of-range values every arm used to emit, and one of them was a silent three-day
    /// roll rather than a visible rejection.
    static func validatedRRuleUntil(_ raw: String, allDay: Bool, zone: TimeZone) -> String? {
        let compact = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
        let isNumeric: (String) -> Bool = { $0.allSatisfy { $0.isASCII && $0.isNumber } }

        // Parse the input into (date, optional time, whether it declared UTC). Shape check first, so no
        // arbitrary text can reach the rule regardless of what the conversion below does.
        var datePart = ""
        var timePart: String?
        var inputIsUTC = false
        if compact.count == 8, isNumeric(compact) {
            datePart = compact
        } else {
            let scalars = Array(compact)
            guard scalars.count == 15 || scalars.count == 16,
                  scalars[8] == "T",
                  scalars.count == 15 || scalars[15] == "Z" else { return nil }
            let d = String(scalars[0..<8])
            let t = String(scalars[9..<15])
            guard isNumeric(d), isNumeric(t) else { return nil }
            datePart = d
            timePart = t
            inputIsUTC = scalars.count == 16
        }

        // VALUE-RANGE CHECK. The block above proves the SHAPE (8 or 6 ASCII digits in the right
        // slots); it says nothing about whether those digits name a real instant, and until this
        // guard existed all three arms below returned out-of-range values. Each arm validates
        // exactly the fields it emits, which is why this is two guards rather than one: the all-day
        // arm keeps its documented behaviour of dropping a supplied time rather than rejecting the
        // date the user meant.
        guard Self.rruleUntilDateIsInRange(datePart) else { return nil }

        // All-day: DTSTART is `VALUE=DATE`, so UNTIL must be a bare DATE. A supplied time is dropped
        // rather than rejected — the date is the part the user meant.
        if allDay { return datePart }

        if let timePart, !Self.rruleUntilTimeIsInRange(timePart) { return nil }

        // Timed: UNTIL must be UTC. Already UTC ⇒ emit as-is.
        if inputIsUTC, let timePart { return "\(datePart)T\(timePart)Z" }

        // Naive (or date-only) ⇒ read it in the event's zone and render the same instant in UTC.
        //
        // `locale` is `en_US_POSIX` and `calendar` is explicitly Gregorian because the parse must be
        // frame-independent: a device on a non-Gregorian calendar or a locale with non-ASCII digits
        // would otherwise fail to read a wire-format string it produced itself.
        //
        // ⚠️ The assignment ORDER of `calendar` and `timeZone` is NOT load-bearing, and an earlier
        // version of this comment claimed it was. The theory was that setting `DateFormatter.calendar`
        // also adopts that calendar's time zone (a fresh `Calendar(identifier: .gregorian)` carries the
        // DEVICE zone), silently discarding the event's zone. That is false for `DateFormatter`: it
        // keeps its own `timeZone` override, and a standalone check produced the identical instant with
        // `timeZone` assigned first and last. The theory was invented to explain a failing assertion
        // whose real cause was on the TEST side — a hardcoded UTC−8 offset for a named zone whose
        // tzdata on the build host sits at UTC−7 year-round (see `untilIsValidated`). Do not reinstate
        // the ordering claim, and do not treat this ordering as a guard.
        let naive = timePart.map { "\(datePart)T\($0)" } ?? "\(datePart)T235959"
        let inFmt = DateFormatter()
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        inFmt.calendar = Calendar(identifier: .gregorian)
        inFmt.dateFormat = "yyyyMMdd'T'HHmmss"
        inFmt.timeZone = zone
        guard let instant = inFmt.date(from: naive) else { return nil }
        let outFmt = DateFormatter()
        outFmt.locale = Locale(identifier: "en_US_POSIX")
        outFmt.calendar = Calendar(identifier: .gregorian)
        outFmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        outFmt.timeZone = TimeZone(identifier: "UTC")
        return outFmt.string(from: instant)
    }

    /// Is a compact `YYYYMMDD` a date that exists? Callers have already proved eight ASCII digits.
    ///
    /// ⚠️ **This is the check the doc comment's *"anything unparseable returns nil"* promised and did
    /// not do**, and every case below is measured, not supposed:
    ///
    ///   - **All-day arm** — returned `20261340`, `00000000`, `99999999`, `20261232` and `20260229`
    ///     (2026 is not a leap year) verbatim, straight into the emitted `RRULE`.
    ///   - **Already-UTC arm** — returned `20261340T120000Z` and `00000000T000000Z`.
    ///   - **Naive arm** — the worse one, and a regression introduced when the naive→UTC conversion
    ///     was added: `DateFormatter` REJECTS month 13 and day 32 but silently ROLLS an out-of-range
    ///     day within a real month, so `20260230` became `20260303T075959Z` and `20260231` became
    ///     `20260304T075959Z`. A wrong instant up to three days out, accepted silently, where the
    ///     previous version returned the value verbatim and a strict server rejected it VISIBLY.
    ///
    /// Written out here rather than delegated to `DateFormatter` because the formatter is wrong in
    /// both directions for this job: too lenient on the day (it rolls), and too strict on the second
    /// (see `rruleUntilTimeIsInRange`).
    private static func rruleUntilDateIsInRange(_ date: String) -> Bool {
        guard date.count == 8,
              let year = Int(date.prefix(4)),
              let month = Int(date.dropFirst(4).prefix(2)),
              let day = Int(date.suffix(2)),
              (1...12).contains(month) else { return false }
        return day >= 1 && day <= Self.gregorianDaysInMonth(month: month, year: year)
    }

    /// Is a compact `HHMMSS` a time RFC 5545 permits? Callers have already proved six ASCII digits.
    ///
    /// **Second `60` is deliberately legal.** RFC 5545 §3.3.12's `time` production is
    /// `time-hour time-minute time-second [Z]` with `time-second = 2DIGIT ;00-60`, i.e. a positive
    /// leap second is a valid wire value. `DateFormatter` refuses it, which is the second reason this
    /// range check is hand-written: delegating would reject a value the spec permits.
    ///
    /// Only the already-UTC arm can carry a leap second through, because that arm emits its input
    /// unchanged. The naive arm still returns nil for `T235960` — measured — because it must parse
    /// the value into an instant before it can re-render it in UTC, and that parse is the
    /// `DateFormatter` one. That is pre-existing behaviour this guard neither creates nor widens.
    ///
    /// The reachable input: `until: "2016-12-31T15:59:60"` with `allDay: false` in a UTC−8 zone is the
    /// LOCAL spelling of the real 2016 positive leap second (`1483228800`), a legal RFC 5545 value this
    /// range check accepts and the naive arm then drops — omitting the `UNTIL`, leaving it unbounded.
    private static func rruleUntilTimeIsInRange(_ time: String) -> Bool {
        guard time.count == 6,
              let hour = Int(time.prefix(2)),
              let minute = Int(time.dropFirst(2).prefix(2)),
              let second = Int(time.suffix(2)) else { return false }
        return (0...23).contains(hour) && (0...59).contains(minute) && (0...60).contains(second)
    }

    /// Days in `month` (1–12) of `year` in the proleptic Gregorian calendar, leap-year-correct.
    /// Deliberately arithmetic rather than `Calendar.range(of:in:for:)`: this runs inside a wire-format
    /// validator that must not depend on the device's current calendar or locale.
    private static func gregorianDaysInMonth(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return isLeap ? 29 : 28
        }
    }

    /// Convert a naive ISO string (yyyy-MM-dd'T'HH:mm:ss) to RFC 3339 with timezone offset.
    private static func toRFC3339(_ naiveISO: String, timeZone: TimeZone) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = timeZone
        guard let date = fmt.date(from: naiveISO) else {
            // Try date-only
            fmt.dateFormat = "yyyy-MM-dd"
            guard let dateOnly = fmt.date(from: naiveISO) else { return naiveISO }
            return dateOnly.iso8601String(timeZone: timeZone)
        }
        return date.iso8601String(timeZone: timeZone)
    }

    // MARK: - Attendee Delta (calendar_event_edit-v1.5.21)

    /// Parse an `add_attendees`-shaped argument into a list of (email, name) tuples.
    /// Accepts `[{ "email": "...", "name": "..." }]` (canonical), `[{ "email": "..." }]`,
    /// or `["bare@email.com"]`. Empty/missing emails are dropped.
    static func parseAttendeeAdds(_ value: JSONValue?) -> [(email: String, name: String?)] {
        guard case .array(let arr) = value else { return [] }
        return arr.compactMap { item -> (email: String, name: String?)? in
            if case .dictionary(let dict) = item,
               case .string(let rawEmail) = dict["email"] {
                let email = stripMailto(rawEmail).trimmingCharacters(in: .whitespaces)
                guard !email.isEmpty, email != "*" else { return nil }
                let name: String? = if case .string(let n) = dict["name"], !n.isEmpty { n } else { nil }
                return (email: email, name: name)
            }
            if case .string(let rawEmail) = item {
                let email = stripMailto(rawEmail).trimmingCharacters(in: .whitespaces)
                guard !email.isEmpty, email != "*" else { return nil }
                return (email: email, name: nil)
            }
            return nil
        }
    }

    /// Parse a `remove_attendees`-shaped argument into a list of emails (or `"*"` literal
    /// for clear-all). Accepts `[{ "email": "..." }]` or `["bare@email.com"]`.
    static func parseAttendeeRemoves(_ value: JSONValue?) -> [String] {
        guard case .array(let arr) = value else { return [] }
        return arr.compactMap { item -> String? in
            if case .dictionary(let dict) = item,
               case .string(let raw) = dict["email"] {
                let trimmed = stripMailto(raw).trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            if case .string(let raw) = item {
                let trimmed = stripMailto(raw).trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
    }

    /// Apply an add/remove delta on top of `base`. Matching for removals is case-insensitive
    /// on the email address. A remove list containing `"*"` (literal) means "clear all — drop
    /// everything in `base`". Adds are appended after removes, de-duped case-insensitively
    /// against whatever's left. When the same email appears in `base` and `adds` with a
    /// different name, the base entry's name is kept (the existing record wins).
    /// Mirrors `EmailReplyTool.applyRecipientDelta`.
    static func applyAttendeeDelta(
        base: [(email: String, name: String?)],
        adds: [(email: String, name: String?)],
        removes: [String]
    ) -> [(email: String, name: String?)] {
        let clearAll = removes.contains { $0.trimmingCharacters(in: .whitespaces) == "*" }
        var result: [(email: String, name: String?)]
        if clearAll {
            result = []
        } else {
            let removeSet = Set(removes
                .filter { $0.trimmingCharacters(in: .whitespaces) != "*" }
                .map { $0.lowercased() })
            result = base.filter { !removeSet.contains($0.email.lowercased()) }
        }
        var seen = Set(result.map { $0.email.lowercased() })
        for add in adds {
            let key = add.email.lowercased()
            if seen.insert(key).inserted {
                result.append(add)
            }
        }
        return result
    }

    /// Strip an optional `mailto:` prefix from an email-shaped string (case-insensitive).
    /// Provider attendee lists (especially TB / CalDAV) sometimes carry the URI form.
    static func stripMailto(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("mailto:") {
            return String(trimmed.dropFirst("mailto:".count))
        }
        return trimmed
    }
}
