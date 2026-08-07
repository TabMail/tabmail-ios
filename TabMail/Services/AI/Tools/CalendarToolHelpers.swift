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

        if let start = event.startDate {
            lines.append("start_iso: \(EKEventStoreHelper.toNaiveISO(start, timeZone: tz))")
        }
        if let end = event.endDate {
            lines.append("end_iso: \(EKEventStoreHelper.toNaiveISO(end, timeZone: tz))")
        }
        // 🚨 `timezone:` NAMES THE ZONE `start_iso`/`end_iso` ARE EXPRESSED IN,
        // AND NOTHING ELSE. It is `tz` — the resolved display zone — because that
        // is what `toNaiveISO` was just handed.
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
    /// Same pattern as AccountManagerCalendarQueue.isCalendarNotFoundError.
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
        if case .dictionary(let rec) = arguments["recurrence"],
           case .string(let freq) = rec["freq"] {
            var rrule = "RRULE:FREQ=\(freq.uppercased())"
            if case .int(let n) = rec["interval"], n > 1 { rrule += ";INTERVAL=\(n)" }
            else if case .double(let d) = rec["interval"], Int(d) > 1 { rrule += ";INTERVAL=\(Int(d))" }
            if case .int(let count) = rec["count"] { rrule += ";COUNT=\(count)" }
            else if case .double(let count) = rec["count"] { rrule += ";COUNT=\(Int(count))" }
            else if case .string(let until) = rec["until"] { rrule += ";UNTIL=\(until.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "T", with: "T"))" }
            input.recurrence = [rrule]
        }

        return input
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
