/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import CryptoKit

/// Protocol for calendar providers (Google Calendar, Microsoft Graph Calendar).
/// Both providers return shared `GCalEvent`/`GCalCalendar` model types to keep calendar tools provider-agnostic.
protocol CalendarProvider: Sendable {
    func listCalendars() async throws -> [GCalCalendar]
    func primaryCalendarId() async throws -> String
    func listEvents(calendarId: String, timeMin: Date?, timeMax: Date?, query: String?, singleEvents: Bool, maxResults: Int, orderBy: String) async throws -> [GCalEvent]
    func getEvent(calendarId: String, eventId: String) async throws -> GCalEvent
    func createEvent(calendarId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent
    func updateEvent(calendarId: String, eventId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent
    func deleteEvent(calendarId: String, eventId: String, sendUpdates: String) async throws

    /// Update a SINGLE OCCURRENCE of a recurring event (this_only edit_scope).
    /// `recurrenceId` is the start datetime of the target occurrence in naive
    /// ISO8601 form (e.g. "2026-05-20T17:00:00"). The provider materializes the
    /// occurrence as an override and applies `event` to it.
    /// Default implementation falls back to series-wide updateEvent so existing
    /// callers stay correct; recurring-aware providers (Google) override.
    func updateOccurrence(calendarId: String, eventId: String, recurrenceId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent

    /// Split a recurring series at `recurrenceId` (this_and_following edit_scope):
    /// cap the original series with UNTIL = recurrenceId - 1, then create a new
    /// series with the same RRULE starting at `recurrenceId` with `patch` applied.
    /// `sendUpdates` controls invitation emails for the NEW series only — the
    /// master cap is silent so attendees see one notification, not two.
    /// Default implementation throws `CalendarProviderError.notSupported` —
    /// providers that don't natively expose split semantics surface this to the
    /// LLM so it can fall back to manual orchestration or ask the user.
    func splitSeries(calendarId: String, eventId: String, recurrenceId: String, patch: GCalEventInput, sendUpdates: String) async throws -> GCalEvent
}

/// Errors common to calendar providers when an operation isn't supported.
enum CalendarProviderError: Error {
    /// The provider can't natively perform this operation (e.g. recurring-series
    /// split on Exchange/CalDAV/Demo before those implementations land).
    case notSupported(String)
}

// Default protocol methods: provide a fallback for providers that haven't
// implemented the recurring-aware paths yet. These keep existing callers
// compiling while letting newly-aware providers override.
extension CalendarProvider {
    func updateOccurrence(calendarId: String, eventId: String, recurrenceId: String, event: GCalEventInput, sendUpdates: String) async throws -> GCalEvent {
        throw CalendarProviderError.notSupported("Editing a single occurrence of a recurring event is not yet supported on this calendar provider. Edit the whole series or use the Thunderbird add-on for fine-grained occurrence edits.")
    }
    func splitSeries(calendarId: String, eventId: String, recurrenceId: String, patch: GCalEventInput, sendUpdates: String) async throws -> GCalEvent {
        throw CalendarProviderError.notSupported("Splitting a recurring series at a given occurrence is not yet supported on this calendar provider. Edit the whole series or use the Thunderbird add-on for this-and-following edits.")
    }
}

/// Google Calendar API v3 provider for Gmail accounts.
/// Mirrors `GmailProvider` actor pattern — same `accessToken` closure, same retry logic.
/// Google handles invitations natively via `sendUpdates=all` — no ICS generation needed.
actor GoogleCalendarProvider: CalendarProvider {
    private let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    private let baseURL = "https://www.googleapis.com/calendar/v3"

    init(accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        self.accessToken = accessToken
    }

    // MARK: - Calendars

    func listCalendars() async throws -> [GCalCalendar] {
        var allCalendars: [GCalCalendar] = []
        var pageToken: String?

        repeat {
            var path = "/users/me/calendarList?maxResults=250"
            if let token = pageToken {
                path += "&pageToken=\(token)"
            }
            let data = try await request(path: path)
            let response = try JSONDecoder().decode(GCalCalendarListResponse.self, from: data)
            allCalendars.append(contentsOf: response.items ?? [])
            pageToken = response.nextPageToken
        } while pageToken != nil

        // Sort: primary first, then writable, then read-only
        allCalendars.sort { a, b in
            if a.primary != b.primary { return a.primary == true }
            let aWritable = a.accessRole == "owner" || a.accessRole == "writer"
            let bWritable = b.accessRole == "owner" || b.accessRole == "writer"
            if aWritable != bWritable { return aWritable }
            return (a.summary ?? "") < (b.summary ?? "")
        }

        // Google's calendarList omits `selected` for unselected calendars (returns
        // it only when true). The API doc states the default is `false`, so
        // normalize nil → false here. This lets the caller filter purely on
        // `selected == false` and keeps Exchange/CalDAV's nil-means-include
        // semantics intact (those providers never set `selected`).
        let normalized = allCalendars.map { cal in
            GCalCalendar(
                id: cal.id,
                summary: cal.summary,
                primary: cal.primary,
                accessRole: cal.accessRole,
                backgroundColor: cal.backgroundColor,
                selected: cal.selected ?? false
            )
        }
        print("[GoogleCalendar] Listed \(normalized.count) calendars")
        for cal in normalized {
            print("[GoogleCalendar]   id=\(cal.id) name='\(cal.summary ?? "?")' primary=\(cal.primary == true) selected=\(cal.selected.map(String.init(describing:)) ?? "nil") accessRole=\(cal.accessRole ?? "?")")
        }
        return normalized
    }

    func primaryCalendarId() async throws -> String {
        let calendars = try await listCalendars()
        return calendars.first(where: { $0.primary == true })?.id ?? "primary"
    }

    // MARK: - Events

    func listEvents(
        calendarId: String = "primary",
        timeMin: Date? = nil,
        timeMax: Date? = nil,
        query: String? = nil,
        singleEvents: Bool = true,
        maxResults: Int = 250,
        orderBy: String = "startTime"
    ) async throws -> [GCalEvent] {
        let encodedCalId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        var queryItems: [String] = []
        // Restrict to default calendar entries; excludes workingLocation / focusTime /
        // outOfOffice / birthday / fromGmail (these often have empty `summary` and
        // are status markers, not user-actionable events).
        queryItems.append("eventTypes=default")
        queryItems.append("singleEvents=\(singleEvents)")
        queryItems.append("maxResults=\(maxResults)")
        if singleEvents {
            queryItems.append("orderBy=\(orderBy)")
        }
        if let timeMin {
            queryItems.append("timeMin=\(timeMin.iso8601String().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        }
        if let timeMax {
            queryItems.append("timeMax=\(timeMax.iso8601String().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        }
        if let query, !query.isEmpty {
            queryItems.append("q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)")
        }

        let path = "/calendars/\(encodedCalId)/events?\(queryItems.joined(separator: "&"))"
        print("[GoogleCalendar] listEvents calendarId='\(calendarId)' path=\(path)")
        let data = try await request(path: path)
        if let preview = String(data: data, encoding: .utf8) {
            print("[GoogleCalendar] listEvents response (first 800 chars): \(preview.prefix(800))")
        }
        let response = try JSONDecoder().decode(GCalEventListResponse.self, from: data)
        let raw = response.items ?? []
        let filtered = raw.filter { $0.status != "cancelled" }
        print("[GoogleCalendar] listEvents calendarId='\(calendarId)' rawCount=\(raw.count) afterCancelFilter=\(filtered.count)")
        for ev in filtered {
            let isEmpty = (ev.summary?.isEmpty ?? true)
                && (ev.attendees?.isEmpty ?? true)
                && (ev.location?.isEmpty ?? true)
                && (ev.description?.isEmpty ?? true)
            let marker = isEmpty ? "EMPTY" : "ok"
            print("[GoogleCalendar]   [\(marker)] id=\(ev.id ?? "?") iCalUID=\(ev.iCalUID ?? "?") eventType=\(ev.eventType ?? "?") kind=\(ev.kind ?? "?") visibility=\(ev.visibility ?? "?") status=\(ev.status ?? "?") summary='\(ev.summary ?? "")' attendees=\(ev.attendees?.count ?? 0) location='\(ev.location ?? "")' desc.len=\(ev.description?.count ?? 0) htmlLink=\(ev.htmlLink ?? "?")")
        }
        return filtered
    }

    func getEvent(calendarId: String = "primary", eventId: String) async throws -> GCalEvent {
        let encodedCalId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        let encodedEventId = eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId
        let data = try await request(path: "/calendars/\(encodedCalId)/events/\(encodedEventId)")
        return try JSONDecoder().decode(GCalEvent.self, from: data)
    }

    func createEvent(
        calendarId: String = "primary",
        event: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        let encodedCalId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        let body = try JSONSerialization.data(withJSONObject: event.toJSON())
        let data = try await request(
            path: "/calendars/\(encodedCalId)/events?sendUpdates=\(sendUpdates)",
            method: "POST",
            body: body
        )
        return try JSONDecoder().decode(GCalEvent.self, from: data)
    }

    func updateEvent(
        calendarId: String = "primary",
        eventId: String,
        event: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        // Always fetch the existing event and merge the patch onto it, so we
        // PATCH a FULL payload. Google's docs say partial PATCH preserves
        // unspecified fields and even recommend "prefer GET + UPDATE over
        // PATCH" for events — this matches CalDAV's natural full-resource
        // PUT and the Exchange Graph fix where partial PATCH on master
        // recurrence silently rewrote start/end. Defense-in-depth.
        let existing = try await getEvent(calendarId: calendarId, eventId: eventId)
        let merged = Self.mergeExistingEventWithPatch(existing: existing, patch: event)
        let encodedCalId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        let encodedEventId = eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId
        let body = try JSONSerialization.data(withJSONObject: merged.toJSON())
        let data = try await request(
            path: "/calendars/\(encodedCalId)/events/\(encodedEventId)?sendUpdates=\(sendUpdates)",
            method: "PATCH",
            body: body
        )
        return try JSONDecoder().decode(GCalEvent.self, from: data)
    }

    func deleteEvent(
        calendarId: String = "primary",
        eventId: String,
        sendUpdates: String = "all"
    ) async throws {
        let encodedCalId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        let encodedEventId = eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId
        _ = try await request(
            path: "/calendars/\(encodedCalId)/events/\(encodedEventId)?sendUpdates=\(sendUpdates)",
            method: "DELETE"
        )
    }

    /// Update a single occurrence of a recurring series — Google Calendar exposes
    /// instances as their own event resources with id of the form
    /// `{masterId}_{YYYYMMDDTHHMMSSZ}`. We resolve the instance via the
    /// `events/{masterId}/instances` endpoint (which gives us the actual
    /// instance id, including DST-adjusted time), then PATCH that instance.
    func updateOccurrence(
        calendarId: String = "primary",
        eventId: String,
        recurrenceId: String,
        event: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        // The agent often passes an INSTANCE id (Google format
        // `<masterId>_<startTime>Z`) when editing a single occurrence. Google's
        // `/events/{id}/instances` endpoint requires the master id — passing an
        // instance returns 400. Resolve up front via the instance's
        // `recurringEventId` pointer.
        let (eventId, _) = try await resolveToMaster(calendarId: calendarId, eventId: eventId)
        let encodedCalId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        let encodedMasterId = eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId

        // Find the instance whose start matches recurrenceId. Google's instances
        // endpoint accepts originalStart query (in RFC 3339) but parsing that
        // requires the master's timezone; safer to fetch a small window around
        // the recurrenceId and match by start.
        let instanceId = try await resolveInstanceId(
            calendarId: encodedCalId,
            masterId: encodedMasterId,
            recurrenceId: recurrenceId
        )
        let encodedInstanceId = instanceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? instanceId

        // Fetch the actual instance event and merge the patch onto it — same
        // defensive full-payload pattern as `updateEvent`. Then strip
        // `recurrence`: an instance/exception cannot carry a series rule and
        // Google rejects PATCHes that include one.
        let existingInstance = try await getEvent(calendarId: calendarId, eventId: instanceId)
        var instancePatch = Self.mergeExistingEventWithPatch(existing: existingInstance, patch: event)
        instancePatch.recurrence = nil
        let body = try JSONSerialization.data(withJSONObject: instancePatch.toJSON())
        let data = try await request(
            path: "/calendars/\(encodedCalId)/events/\(encodedInstanceId)?sendUpdates=\(sendUpdates)",
            method: "PATCH",
            body: body
        )
        return try JSONDecoder().decode(GCalEvent.self, from: data)
    }

    /// Split a recurring series at `recurrenceId`:
    /// 1. PATCH the master to add UNTIL = recurrenceId - 1 second (silent — sendUpdates="none")
    /// 2. POST a new event with the same fields as the master, the `patch` applied,
    ///    DTSTART = recurrenceId, and the master's RRULE without UNTIL/COUNT.
    /// If step 2 fails after step 1 succeeded, attempt to revert step 1.
    /// Invitations (`sendUpdates`) fire only on the new series.
    func splitSeries(
        calendarId: String = "primary",
        eventId: String,
        recurrenceId: String,
        patch: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        // 1. Fetch the master so we can preserve its fields and read its RRULE.
        //    The agent may have passed an INSTANCE id (Google format
        //    `<masterId>_<startTime>Z`) — instances don't carry the RRULE, only
        //    the master does. Resolve via `recurringEventId` so a split aimed at
        //    an occurrence id still finds the series to cap.
        let (eventId, master) = try await resolveToMaster(calendarId: calendarId, eventId: eventId)
        guard let masterRecurrence = master.recurrence, !masterRecurrence.isEmpty else {
            throw CalendarProviderError.notSupported("Event \(eventId) is not recurring; can't split.")
        }

        // 2. Locate the master's RRULE line and compute the capped variant.
        guard let originalRRule = masterRecurrence.first(where: { $0.uppercased().hasPrefix("RRULE:") }) else {
            throw CalendarProviderError.notSupported("Master event has no RRULE; can't split.")
        }
        guard let untilValue = Self.googleUntilString(beforeNaiveISO: recurrenceId, allDay: master.isAllDay) else {
            throw CalendarProviderError.notSupported("Invalid recurrence_id '\(recurrenceId)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        }
        let cappedRRule = Self.replaceOrAppendUntil(in: originalRRule, untilValue: untilValue)
        let rruleWithoutCap = Self.stripUntilAndCount(originalRRule)

        // 3. Build the capped-master patch. The semantic change is recurrence-
        //    only, but defensive-include the master's existing start/end so
        //    the provider can't silently re-anchor them on partial PATCH.
        //    Google's docs explicitly recommend "prefer GET + UPDATE over
        //    PATCH" for events — sending the unchanged fields makes the
        //    intent crystal clear and parallels the Exchange Graph fix where
        //    omitting start/end caused the master to be rewritten to UTC
        //    midnight at `range.startDate`.
        var cappedMasterInput = GCalEventInput()
        cappedMasterInput.recurrence = [cappedRRule]
        if master.isAllDay {
            if let s = master.start?.date { cappedMasterInput.startDate = s }
            if let e = master.end?.date { cappedMasterInput.endDate = e }
        } else {
            if let s = master.start?.dateTime { cappedMasterInput.startDateTime = s }
            if let tz = master.start?.timeZone { cappedMasterInput.startTimeZone = tz }
            if let e = master.end?.dateTime { cappedMasterInput.endDateTime = e }
            if let tz = master.end?.timeZone { cappedMasterInput.endTimeZone = tz }
        }

        // 4. PATCH master silently.
        let _: GCalEvent = try await updateEvent(
            calendarId: calendarId,
            eventId: eventId,
            event: cappedMasterInput,
            sendUpdates: "none"
        )

        // 5. Build the new series — inherit master fields, apply patch overrides.
        //    Pin a DETERMINISTIC id so a retry after a lost ACK on step 6
        //    re-targets the same series instead of creating a duplicate.
        var newSeriesInput = Self.mergeMasterAndPatch(
            master: master,
            patch: patch,
            newStartNaiveISO: recurrenceId,
            newRecurrence: [rruleWithoutCap]
        )
        let newSeriesId = Self.deterministicSplitEventId(masterId: eventId, recurrenceId: recurrenceId)
        newSeriesInput.id = newSeriesId

        // 6. Create the new series.
        do {
            return try await createEvent(
                calendarId: calendarId,
                event: newSeriesInput,
                sendUpdates: sendUpdates
            )
        } catch GoogleCalendarError.httpError(409, _) {
            // 409 Conflict — the new series with this deterministic id already
            // exists from a prior (lost-ACK) attempt. The split already
            // completed; do NOT revert the master cap. Return the existing
            // series so the retry settles as success.
            return try await getEvent(calendarId: calendarId, eventId: newSeriesId)
        } catch {
            // Best-effort revert of step 1 so we don't leave the master truncated
            // with no replacement series. Same defensive include-start/end as
            // the cap above — partial PATCH could in principle re-anchor.
            var revertInput = GCalEventInput()
            revertInput.recurrence = masterRecurrence
            if master.isAllDay {
                if let s = master.start?.date { revertInput.startDate = s }
                if let e = master.end?.date { revertInput.endDate = e }
            } else {
                if let s = master.start?.dateTime { revertInput.startDateTime = s }
                if let tz = master.start?.timeZone { revertInput.startTimeZone = tz }
                if let e = master.end?.dateTime { revertInput.endDateTime = e }
                if let tz = master.end?.timeZone { revertInput.endTimeZone = tz }
            }
            _ = try? await updateEvent(
                calendarId: calendarId,
                eventId: eventId,
                event: revertInput,
                sendUpdates: "none"
            )
            throw error
        }
    }

    // MARK: - Recurring helpers

    /// If `eventId` points to an OCCURRENCE of a recurring series (Google
    /// format: `<masterId>_<startTime>Z`), fetch the master and return its
    /// id + event. Otherwise return the originally-fetched event as the master.
    ///
    /// Google instance events do NOT carry the series `recurrence` — only the
    /// master does. So `splitSeries` / `updateOccurrence` called directly with
    /// an instance id would either fail ("not recurring; can't split") or hit
    /// the `/events/{id}/instances` endpoint with the wrong id and 400. The
    /// agent commonly passes an instance id because that's what
    /// `calendar_search` / `calendar_read` returns for an occurrence — resolve
    /// up front so split/updateOccurrence see the master regardless.
    private func resolveToMaster(calendarId: String, eventId: String) async throws -> (id: String, event: GCalEvent) {
        let fetched = try await getEvent(calendarId: calendarId, eventId: eventId)
        if let masterId = fetched.recurringEventId, !masterId.isEmpty, masterId != eventId {
            let master = try await getEvent(calendarId: calendarId, eventId: masterId)
            return (masterId, master)
        }
        return (eventId, fetched)
    }

    /// Find the Google instance id for `recurrenceId` by hitting the instances
    /// endpoint with a wide-enough window to tolerate DST transitions and
    /// device/event timezone mismatches.
    /// Window rationale: ±25 hours covers (a) DST shifts of up to 1h either
    /// way, (b) a worst-case device-vs-event timezone delta (e.g. UTC+14 vs
    /// UTC-12 = 26h difference — close to the limit but covered by the
    /// instances-endpoint's recurrence-aware filtering), and (c) all-day
    /// events where the instance start may be midnight in a different zone.
    /// We narrow back to the correct instance via day-prefix matching below.
    private func resolveInstanceId(calendarId: String, masterId: String, recurrenceId: String) async throws -> String {
        // recurrenceId is naive ISO; treat as device-local for the window math.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = .current
        guard let centerDate = fmt.date(from: String(recurrenceId)) else {
            // Fall back to date-only form (e.g. "2026-05-20" for an all-day event)
            // before declaring the recurrenceId malformed.
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd"
            dateFmt.timeZone = TimeZone(identifier: "UTC")
            guard dateFmt.date(from: String(recurrenceId.prefix(10))) != nil else {
                throw GoogleCalendarError.eventNotFound
            }
            // Recurse with a normalized full-day form so the rest of the path
            // can use a single code branch.
            return try await resolveInstanceId(
                calendarId: calendarId, masterId: masterId,
                recurrenceId: "\(recurrenceId.prefix(10))T00:00:00"
            )
        }
        let windowSeconds: TimeInterval = 25 * 60 * 60
        let minDate = centerDate.addingTimeInterval(-windowSeconds)
        let maxDate = centerDate.addingTimeInterval(windowSeconds)
        let rfc3339 = ISO8601DateFormatter()
        rfc3339.formatOptions = [.withInternetDateTime]
        let timeMin = rfc3339.string(from: minDate)
        let timeMax = rfc3339.string(from: maxDate)

        let encodedTimeMin = timeMin.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? timeMin
        let encodedTimeMax = timeMax.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? timeMax
        let data = try await request(
            path: "/calendars/\(calendarId)/events/\(masterId)/instances?timeMin=\(encodedTimeMin)&timeMax=\(encodedTimeMax)"
        )
        let resp = try JSONDecoder().decode(GCalEventListResponse.self, from: data)
        let items = resp.items ?? []
        let dayPrefix = String(recurrenceId.prefix(10))
        // First try strict day-prefix match against the instance's start (handles
        // DST inside the window). Fall back to the first instance only if exactly
        // ONE instance came back — multiple instances + no day-match means we
        // can't pick safely, so throw.
        if let dayMatch = items.first(where: { ev in
            guard let start = ev.start?.dateTime ?? ev.start?.date else { return false }
            return start.hasPrefix(dayPrefix)
        }), let id = dayMatch.id {
            return id
        }
        if items.count == 1, let id = items[0].id {
            return id
        }
        throw GoogleCalendarError.eventNotFound
    }

    /// Produce an RFC 5545 UNTIL value for capping a series just before the
    /// occurrence at naive-ISO `naive`.
    ///
    /// RFC 5545 §3.3.10: the UNTIL value type MUST match DTSTART's value type.
    ///   - Timed event (DTSTART is a date-time with a timezone) → UNTIL must be
    ///     a UTC date-time: `YYYYMMDDTHHMMSSZ`. We use (split − 1 second).
    ///   - All-day event (DTSTART is VALUE=DATE) → UNTIL must be a bare DATE:
    ///     `YYYYMMDD`. We use (split − 1 day) so the split day's occurrence is
    ///     excluded (UNTIL is inclusive of the date for all-day rules).
    ///
    /// `naive` is interpreted as device-local time. Accepts both the full
    /// `2026-05-20T17:00:00` form and the date-only `2026-05-20` form (the
    /// latter is what an all-day occurrence's recurrence_id looks like).
    /// Returns nil if the input is unparseable — callers MUST handle this
    /// (silently emitting "now-1s" would cap the series in the past with
    /// nothing in the new series).
    static func googleUntilString(beforeNaiveISO naive: String, allDay: Bool) -> String? {
        // Parse: try full date-time first, then fall back to date-only.
        let dtFmt = DateFormatter()
        dtFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        dtFmt.timeZone = .current
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone = .current
        let parsed = dtFmt.date(from: naive)
            ?? dateFmt.date(from: String(naive.prefix(10)))
        guard let date = parsed else { return nil }

        if allDay {
            // Day before, bare DATE form. Use Calendar arithmetic — subtracting
            // a flat 86400s lands on the wrong wall-clock day across a DST
            // transition (a 23h or 25h local day), which would cap the series
            // a day early/late.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            guard let dayBefore = cal.date(byAdding: .day, value: -1, to: date) else { return nil }
            let out = DateFormatter()
            out.dateFormat = "yyyyMMdd"
            out.timeZone = .current
            return out.string(from: dayBefore)
        }
        // One second before, UTC date-time form.
        let untilDate = date.addingTimeInterval(-1)
        let out = DateFormatter()
        out.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        out.timeZone = TimeZone(identifier: "UTC")
        return out.string(from: untilDate)
    }

    /// Drop any existing UNTIL=... or COUNT=... segments, then append the new UNTIL.
    static func replaceOrAppendUntil(in rrule: String, untilValue: String) -> String {
        // RRULE format: "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=10"
        let prefix = "RRULE:"
        let body = rrule.hasPrefix(prefix) ? String(rrule.dropFirst(prefix.count)) : rrule
        let kept = body.split(separator: ";")
            .map(String.init)
            .filter { part in
                let upper = part.uppercased()
                return !upper.hasPrefix("UNTIL=") && !upper.hasPrefix("COUNT=")
            }
        return prefix + (kept + ["UNTIL=\(untilValue)"]).joined(separator: ";")
    }

    /// Drop UNTIL/COUNT from an RRULE, returning the open-ended pattern.
    static func stripUntilAndCount(_ rrule: String) -> String {
        let prefix = "RRULE:"
        let body = rrule.hasPrefix(prefix) ? String(rrule.dropFirst(prefix.count)) : rrule
        let kept = body.split(separator: ";")
            .map(String.init)
            .filter { part in
                let upper = part.uppercased()
                return !upper.hasPrefix("UNTIL=") && !upper.hasPrefix("COUNT=")
            }
        return prefix + kept.joined(separator: ";")
    }

    /// Deterministic identifier for the NEW series produced by a
    /// `this_and_following` split. Derived purely from inputs that are STABLE
    /// across queue retries (`masterId` + `recurrenceId`), so retrying a split
    /// after a lost ACK targets the SAME resource instead of creating a
    /// duplicate series (the two-step cap-then-create is otherwise not
    /// idempotent — step 1 is, step 2 isn't).
    ///
    /// SHA-256 hex: 64 chars of `[0-9a-f]` — simultaneously a valid subset of
    /// Google's base32hex event-id charset (`a`–`v`, `0`–`9`; length 5–1024),
    /// a safe CalDAV `.ics` filename / URL path component, and well within
    /// Microsoft Graph's `transactionId` length limit.
    static func deterministicSplitEventId(masterId: String, recurrenceId: String) -> String {
        let seed = "tabmail-split|\(masterId)|\(recurrenceId)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Build a "full" `GCalEventInput` representing the patched state of an
    /// existing event, by inheriting unchanged fields from `existing` and
    /// applying `patch` overrides. Used to defend against partial-PATCH
    /// server quirks like Exchange Graph silently rewriting `start`/`end` to
    /// UTC midnight at `range.startDate` when only `recurrence` is sent.
    /// Google's docs even recommend "prefer GET + UPDATE over PATCH" — this
    /// helper makes that pattern available everywhere.
    ///
    /// Attendees are deliberately NOT inherited from `existing`: re-sending
    /// the existing attendees in a PATCH would reset their `responseStatus`
    /// fields (Graph/Google treat re-sent attendees as newly invited). We
    /// only include attendees when `patch` explicitly changes them; the
    /// caller is responsible for delta-resolving against the existing list
    /// (see `AccountManagerCalendarQueue.resolveAttendeeDelta`).
    static func mergeExistingEventWithPatch(existing: GCalEvent, patch: GCalEventInput) -> GCalEventInput {
        var merged = GCalEventInput()
        merged.summary = patch.summary ?? existing.summary
        merged.location = patch.location ?? existing.location
        merged.description = patch.description ?? existing.description
        merged.transparency = patch.transparency ?? existing.transparency

        // Date/time. When the patch moves ONE side (start OR end) without
        // specifying the other, preserve the master's wall-clock duration
        // by deriving the missing side. Without this, "move start to 3 PM"
        // on a 30-min event leaves end at the original wall time, stretching
        // (or inverting) the duration. This matches the LLM's implicit
        // intent — when it omits end_iso, it almost always means "keep the
        // same length, just shift the start."
        let hasPatchStart = patch.startDate != nil || patch.startDateTime != nil
        let hasPatchEnd = patch.endDate != nil || patch.endDateTime != nil
        let masterDuration: TimeInterval? = {
            guard let s = existing.startDate, let e = existing.endDate else { return nil }
            let d = e.timeIntervalSince(s)
            return d > 0 ? d : nil
        }()

        // Resolve start.
        if hasPatchStart {
            merged.startDate = patch.startDate
            merged.startDateTime = patch.startDateTime
            merged.startTimeZone = patch.startTimeZone
        } else if existing.isAllDay {
            merged.startDate = existing.start?.date
        } else {
            merged.startDateTime = existing.start?.dateTime
            merged.startTimeZone = existing.start?.timeZone
        }

        // Resolve end.
        if hasPatchEnd {
            merged.endDate = patch.endDate
            merged.endDateTime = patch.endDateTime
            merged.endTimeZone = patch.endTimeZone
        } else if hasPatchStart, let duration = masterDuration {
            // Derive end = newStart + masterDuration. The LLM moved start
            // without end; preserve duration so a 30-min event stays 30 min.
            if existing.isAllDay, let sd = patch.startDate {
                // For all-day, work in whole days using a calendar so DST
                // boundaries roll correctly.
                let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
                if let startDate = df.date(from: String(sd.prefix(10))) {
                    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
                    let days = max(1, Int((duration / 86400).rounded()))
                    if let endDate = cal.date(byAdding: .day, value: days, to: startDate) {
                        merged.endDate = df.string(from: endDate)
                    }
                }
            } else if let sdt = patch.startDateTime, let startInstant = Date.fromISO8601(sdt) {
                let endInstant = startInstant.addingTimeInterval(duration)
                let tz = patch.startTimeZone.flatMap { TimeZone(identifier: $0) } ?? .current
                merged.endDateTime = endInstant.iso8601String(timeZone: tz)
                merged.endTimeZone = patch.startTimeZone ?? existing.end?.timeZone
            } else {
                // Couldn't parse — fall back to inheriting existing end.
                if existing.isAllDay { merged.endDate = existing.end?.date }
                else { merged.endDateTime = existing.end?.dateTime; merged.endTimeZone = existing.end?.timeZone }
            }
        } else if hasPatchEnd, let duration = masterDuration {
            // Symmetric case: patch moves END only — derive start = newEnd - masterDuration.
            if existing.isAllDay, let ed = patch.endDate {
                let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
                if let endDate = df.date(from: String(ed.prefix(10))) {
                    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
                    let days = max(1, Int((duration / 86400).rounded()))
                    if let startDate = cal.date(byAdding: .day, value: -days, to: endDate) {
                        merged.startDate = df.string(from: startDate)
                    }
                }
            } else if let edt = patch.endDateTime, let endInstant = Date.fromISO8601(edt) {
                let startInstant = endInstant.addingTimeInterval(-duration)
                let tz = patch.endTimeZone.flatMap { TimeZone(identifier: $0) } ?? .current
                merged.startDateTime = startInstant.iso8601String(timeZone: tz)
                merged.startTimeZone = patch.endTimeZone ?? existing.start?.timeZone
            }
        } else if existing.isAllDay {
            merged.endDate = existing.end?.date
        } else {
            merged.endDateTime = existing.end?.dateTime
            merged.endTimeZone = existing.end?.timeZone
        }

        // Recurrence: patch wins; else inherit. (For instance PATCHes,
        // caller must `merged.recurrence = nil` AFTER — instances can't
        // carry a series rule and providers will 400.)
        merged.recurrence = patch.recurrence ?? existing.recurrence

        // Attendees: only set when the patch is changing them. See doc.
        merged.attendees = patch.attendees

        return merged
    }

    /// Build a `GCalEventInput` for the NEW series of a split. Inherits the
    /// master's fields, applies the caller's `patch` on top, and rewrites
    /// start/end/recurrence to the split point.
    static func mergeMasterAndPatch(
        master: GCalEvent,
        patch: GCalEventInput,
        newStartNaiveISO: String,
        newRecurrence: [String]
    ) -> GCalEventInput {
        var out = GCalEventInput()

        out.summary = patch.summary ?? master.summary
        out.location = patch.location ?? master.location
        out.description = patch.description ?? master.description
        out.transparency = patch.transparency ?? master.transparency

        // Start = new split point. End = split point + master's duration.
        // CRITICAL: preserve the master's all-day-ness. An all-day master must
        // produce an all-day new series — emitting startDateTime/endDateTime
        // (the timed form) would silently convert the series to a timed event.
        let durationSec: TimeInterval = {
            guard let s = master.startDate, let e = master.endDate else {
                return master.isAllDay ? 86400 : 3600
            }
            return e.timeIntervalSince(s)
        }()
        if master.isAllDay {
            // All-day: emit date-only start/end. Google's all-day `end.date` is
            // EXCLUSIVE, so a 1-day event is start=D, end=D+1 (durationSec≈86400).
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            let dateOnlyFmt = DateFormatter()
            dateOnlyFmt.dateFormat = "yyyy-MM-dd"
            dateOnlyFmt.timeZone = .current
            let parseFmt = DateFormatter()
            parseFmt.dateFormat = "yyyy-MM-dd"
            parseFmt.timeZone = .current
            // Prefer the patch's explicit new date when the LLM is moving the
            // series with the split. `recurrence_id` only identifies WHICH
            // occurrence the split anchors at — `start_iso` is the user's
            // desired NEW date. Falling back to the recurrence_id silently
            // ignores a move the LLM was asked to perform.
            let preferredStart = patch.startDate ?? String(newStartNaiveISO.prefix(10))
            if let startDate = parseFmt.date(from: String(preferredStart.prefix(10))) {
                out.startDate = dateOnlyFmt.string(from: startDate)
                // End: patch's explicit end wins; else start + master's duration.
                if let patchEnd = patch.endDate, let endDate = parseFmt.date(from: String(patchEnd.prefix(10))) {
                    out.endDate = dateOnlyFmt.string(from: endDate)
                } else {
                    let days = max(1, Int((durationSec / 86400).rounded()))
                    if let endDate = cal.date(byAdding: .day, value: days, to: startDate) {
                        out.endDate = dateOnlyFmt.string(from: endDate)
                    }
                }
            }
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            fmt.timeZone = .current
            // Prefer the patch's explicit new datetime — same rationale as
            // above. The recurrence_id is the "WHICH occurrence" anchor; the
            // patch's start_iso/end_iso is the "WHAT TIME" the new series
            // should be at. Conflating them was silently dropping LLM-issued
            // moves like "split at the 15:00 occurrence and put the new
            // series at 15:30".
            let startInstant: Date? = {
                if let pISO = patch.startDateTime, let d = Date.fromISO8601(pISO) { return d }
                return fmt.date(from: newStartNaiveISO)
            }()
            if let startDate = startInstant {
                let endDate: Date = {
                    if let pISO = patch.endDateTime, let d = Date.fromISO8601(pISO) { return d }
                    return startDate.addingTimeInterval(durationSec)
                }()
                // Use device-local TZ — `iso8601String(timeZone:)` emits the form
                // Google's events API expects (`2026-05-20T17:00:00-07:00`).
                out.startDateTime = startDate.iso8601String(timeZone: .current)
                out.endDateTime = endDate.iso8601String(timeZone: .current)
                // CRITICAL: Google REQUIRES a named `timeZone` on start/end when
                // creating a RECURRING event — an offset alone is ambiguous
                // across DST for recurrence expansion. Without this the new-
                // series POST is rejected with HTTP 400 "Missing time zone
                // definition for start time". Inherit the master's IANA zone;
                // fall back to the device zone if the master didn't carry one.
                out.startTimeZone = master.start?.timeZone ?? TimeZone.current.identifier
                out.endTimeZone = master.end?.timeZone ?? master.start?.timeZone ?? TimeZone.current.identifier
            }
        }

        // Attendees: prefer patch's resolved list, else inherit master's.
        if let patchAttendees = patch.attendees {
            out.attendees = patchAttendees
        } else {
            out.attendees = (master.attendees ?? []).compactMap { att in
                guard let email = att.email, !email.isEmpty else { return nil }
                return (email: email, name: att.displayName)
            }
        }

        // Recurrence: caller-supplied `newRecurrence` is the default (master's
        // RRULE stripped of UNTIL/COUNT). If `patch.recurrence` is non-nil, the
        // LLM/user explicitly asked for a different pattern on the new series —
        // honor that. This keeps iOS consistent with the TB bridge, which also
        // respects patch.recurrence when present.
        if let patchRecurrence = patch.recurrence, !patchRecurrence.isEmpty {
            out.recurrence = patchRecurrence
        } else {
            out.recurrence = newRecurrence
        }
        return out
    }

    // MARK: - HTTP

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let token = try await accessToken(false)
        let result = try await performHTTPRequest(url: baseURL + path, method: method, body: body, token: token, logLabel: "GoogleCalendar")

        if let data = result.data {
            return data
        }

        // 401 — token expired, force refresh and retry once
        if result.statusCode == 401 {
            print("[GoogleCalendar] Token expired, refreshing...")
            let freshToken = try await accessToken(true)
            let retry = try await performHTTPRequest(url: baseURL + path, method: method, body: body, token: freshToken, logLabel: "GoogleCalendar")
            if let data = retry.data {
                return data
            }
            throw GoogleCalendarError.httpError(retry.statusCode, nil)
        }

        // 403 — missing calendar scope
        if result.statusCode == 403 {
            throw GoogleCalendarError.missingScope
        }

        throw GoogleCalendarError.httpError(result.statusCode, result.data)
    }

    // MARK: - Helpers

}

// MARK: - Errors

enum GoogleCalendarError: Error {
    case missingScope
    case httpError(Int, Data?)
    case eventNotFound
}

// MARK: - Response Models

struct GCalCalendar: Codable, Sendable {
    let id: String
    let summary: String?
    let primary: Bool?
    let accessRole: String?
    let backgroundColor: String?
    /// Google Calendar's "show in UI" flag on the calendarList entry. Calendars
    /// the user has unchecked in Google Calendar / iOS Calendar / Thunderbird
    /// come back with `selected: false`. Other providers don't surface this
    /// field — leave nil and treat nil as "selected" (caller decides).
    let selected: Bool?
}

struct GCalCalendarListResponse: Codable, Sendable {
    let items: [GCalCalendar]?
    let nextPageToken: String?
}

struct GCalEvent: Codable, Sendable {
    let id: String?
    let summary: String?
    let location: String?
    let description: String?
    let start: GCalDateTime?
    let end: GCalDateTime?
    let attendees: [GCalAttendee]?
    let organizer: GCalOrganizer?
    let recurrence: [String]?
    let transparency: String?
    let status: String?
    let htmlLink: String?
    let created: String?
    let updated: String?
    /// Diagnostic-only fields — populated from the API response so we can
    /// understand the provenance of empty-title rows. Not consumed by the
    /// rest of the app today; safe to ignore. Add to GCalEventInput as well
    /// before relying on these for write paths.
    let eventType: String?       // "default" / "workingLocation" / "focusTime" / "outOfOffice" / "birthday" / "fromGmail"
    let iCalUID: String?         // RFC 5545 UID — survives across imports / sync
    let kind: String?            // "calendar#event" — sanity check
    let visibility: String?      // "default" / "public" / "private" / "confidential"
    /// Back-reference to the series master when `singleEvents=true` expansion
    /// returned this row as an individual occurrence instance. Google's API
    /// populates this field; the `recurrence` array is then empty on the
    /// instance (the rule lives on the master only). We use this to enrich
    /// the LLM-facing search output with the master's RRULE so a recurring
    /// series's UNTIL/COUNT is visible on every occurrence line.
    let recurringEventId: String?
}

// Convenience initializer that fills in `eventType`/`iCalUID`/`kind`/`visibility`
// with nil so existing call sites (Exchange, CalDAV, ICSParser, tests) don't have
// to thread the diagnostic-only fields. Google's Decodable path uses the
// synthesized memberwise init via `JSONDecoder` and gets the real values.
extension GCalEvent {
    init(
        id: String?,
        summary: String?,
        location: String?,
        description: String?,
        start: GCalDateTime?,
        end: GCalDateTime?,
        attendees: [GCalAttendee]?,
        organizer: GCalOrganizer?,
        recurrence: [String]?,
        transparency: String?,
        status: String?,
        htmlLink: String?,
        created: String?,
        updated: String?,
        recurringEventId: String? = nil
    ) {
        self.init(
            id: id, summary: summary, location: location, description: description,
            start: start, end: end, attendees: attendees, organizer: organizer,
            recurrence: recurrence, transparency: transparency, status: status,
            htmlLink: htmlLink, created: created, updated: updated,
            eventType: nil, iCalUID: nil, kind: nil, visibility: nil,
            recurringEventId: recurringEventId
        )
    }
}

struct GCalDateTime: Codable, Sendable {
    let dateTime: String?  // RFC 3339 for timed events
    let date: String?      // YYYY-MM-DD for all-day events
    let timeZone: String?
}

struct GCalAttendee: Codable, Sendable {
    let email: String?
    let displayName: String?
    let responseStatus: String?
    let organizer: Bool?
    let `self`: Bool?
}

struct GCalOrganizer: Codable, Sendable {
    let email: String?
    let displayName: String?
    let `self`: Bool?
}

struct GCalEventListResponse: Codable, Sendable {
    let items: [GCalEvent]?
    let nextPageToken: String?
}

// MARK: - Input Model

struct GCalEventInput: Sendable {
    /// Pre-generated event ID for idempotent creates (crash recovery).
    var id: String?
    var summary: String?
    var location: String?
    var description: String?
    var startDateTime: String?   // RFC 3339
    var startDate: String?       // YYYY-MM-DD (all-day)
    var startTimeZone: String?
    var endDateTime: String?
    var endDate: String?
    var endTimeZone: String?
    var attendees: [(email: String, name: String?)]?
    var transparency: String?
    var recurrence: [String]?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [:]

        if let id { json["id"] = id }
        if let summary { json["summary"] = summary }
        if let location { json["location"] = location }
        if let description { json["description"] = description }
        if let transparency { json["transparency"] = transparency }

        // Start
        var startObj: [String: Any] = [:]
        if let startDateTime { startObj["dateTime"] = startDateTime }
        if let startDate { startObj["date"] = startDate }
        if let startTimeZone { startObj["timeZone"] = startTimeZone }
        if !startObj.isEmpty { json["start"] = startObj }

        // End
        var endObj: [String: Any] = [:]
        if let endDateTime { endObj["dateTime"] = endDateTime }
        if let endDate { endObj["date"] = endDate }
        if let endTimeZone { endObj["timeZone"] = endTimeZone }
        if !endObj.isEmpty { json["end"] = endObj }

        // Attendees
        if let attendees {
            json["attendees"] = attendees.map { a -> [String: Any] in
                var obj: [String: Any] = ["email": a.email]
                if let name = a.name { obj["displayName"] = name }
                return obj
            }
        }

        // Recurrence
        if let recurrence { json["recurrence"] = recurrence }

        return json
    }
}

// MARK: - GCalEvent Helpers

extension GCalEvent {
    /// Parse start date from either dateTime (timed) or date (all-day).
    var startDate: Date? {
        if let dt = start?.dateTime { return parseRFC3339(dt) }
        if let d = start?.date { return parseDateOnly(d) }
        return nil
    }

    /// Parse end date from either dateTime (timed) or date (all-day).
    var endDate: Date? {
        if let dt = end?.dateTime { return parseRFC3339(dt) }
        if let d = end?.date { return parseDateOnly(d) }
        return nil
    }

    /// Whether this is an all-day event (uses date instead of dateTime).
    var isAllDay: Bool {
        start?.date != nil
    }

    private func parseRFC3339(_ str: String) -> Date? {
        Date.fromISO8601(str)
    }

    private func parseDateOnly(_ str: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        return fmt.date(from: str)
    }
}
