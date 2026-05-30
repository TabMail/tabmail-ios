/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Microsoft Graph Calendar API provider for Exchange/Outlook accounts.
/// Mirrors `GoogleCalendarProvider` actor pattern — same `accessToken` closure, same retry logic.
/// Conforms to `CalendarProvider` protocol — maps Graph responses to shared `GCalEvent`/`GCalCalendar` models.
actor ExchangeCalendarProvider: CalendarProvider {
    private let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    private let baseURL = "https://graph.microsoft.com/v1.0/me"

    init(accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        self.accessToken = accessToken
    }

    // MARK: - Calendars

    func listCalendars() async throws -> [GCalCalendar] {
        print("[ExchangeCalendar] listCalendars starting...")
        let data = try await request(path: "/calendars?$select=id,name,isDefaultCalendar,color")
        print("[ExchangeCalendar] listCalendars raw: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")")
        let response = try JSONDecoder().decode(MSCalendarListResponse.self, from: data)
        return response.value.map { cal in
            GCalCalendar(
                id: cal.id,
                summary: cal.name,
                primary: cal.isDefaultCalendar,
                accessRole: "owner",
                backgroundColor: msColorToHex(cal.color),
                selected: nil
            )
        }
    }

    func primaryCalendarId() async throws -> String {
        let calendars = try await listCalendars()
        let primary = calendars.first(where: { $0.primary == true })?.id ?? "primary"
        print("[ExchangeCalendar] primaryCalendarId = \(primary)")
        return primary
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
        var queryItems: [String] = []
        queryItems.append("$top=\(maxResults)")
        queryItems.append("$orderby=start/dateTime")
        queryItems.append("$select=id,subject,location,bodyPreview,start,end,attendees,organizer,recurrence,showAs,isCancelled,webLink,createdDateTime,lastModifiedDateTime,isAllDay,seriesMasterId")

        let calPath: String
        if calendarId == "primary" {
            calPath = ""
        } else {
            let encodedCalId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
            calPath = "/calendars/\(encodedCalId)"
        }

        // Use calendarView for time-windowed queries (expands recurring events), events endpoint otherwise
        let endpoint: String
        if let timeMin, let timeMax {
            // startDateTime/endDateTime are calendarView-only params
            queryItems.append("startDateTime=\(timeMin.iso8601String())")
            queryItems.append("endDateTime=\(timeMax.iso8601String())")
            endpoint = "\(calPath)/calendarView?\(queryItems.joined(separator: "&"))"
        } else {
            // Without both time bounds, use events endpoint with $filter
            var filterParts: [String] = []
            if let timeMin { filterParts.append("start/dateTime ge '\(timeMin.iso8601String())'") }
            if let timeMax { filterParts.append("end/dateTime le '\(timeMax.iso8601String())'") }
            if !filterParts.isEmpty {
                queryItems.append("$filter=\(filterParts.joined(separator: " and "))")
            }
            endpoint = "\(calPath)/events?\(queryItems.joined(separator: "&"))"
        }

        // Apply query filter client-side if provided (Graph calendarView doesn't support $search)
        print("[ExchangeCalendar] listEvents endpoint: \(endpoint)")
        let data = try await request(path: endpoint)
        print("[ExchangeCalendar] listEvents response: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")")
        let response = try JSONDecoder().decode(MSEventListResponse.self, from: data)

        var events = response.value
            .filter { $0.isCancelled != true }
            .filter { e in
                if isEmptySurfaceEvent(e) {
                    print("[ExchangeCalendar] dropping empty event id=\(e.id ?? "nil")")
                    return false
                }
                return true
            }
            .map { toGCalEvent($0) }

        if let query, !query.isEmpty {
            let lower = query.lowercased()
            events = events.filter { event in
                (event.summary ?? "").lowercased().contains(lower) ||
                (event.location ?? "").lowercased().contains(lower) ||
                (event.description ?? "").lowercased().contains(lower)
            }
        }

        return events
    }

    func getEvent(calendarId: String = "primary", eventId: String) async throws -> GCalEvent {
        let encodedEventId = eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId
        let data = try await request(path: "/events/\(encodedEventId)?$select=id,subject,location,bodyPreview,start,end,attendees,organizer,recurrence,showAs,isCancelled,webLink,createdDateTime,lastModifiedDateTime,isAllDay,seriesMasterId")
        let event = try JSONDecoder().decode(MSEvent.self, from: data)
        return toGCalEvent(event)
    }

    func createEvent(
        calendarId: String = "primary",
        event: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        let calPath: String
        if calendarId == "primary" {
            calPath = ""
        } else {
            let encodedCalId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
            calPath = "/calendars/\(encodedCalId)"
        }

        let body = try JSONSerialization.data(withJSONObject: toGraphEventJSON(event))
        if let bodyStr = String(data: body, encoding: .utf8) {
            print("[ExchangeCalendar] createEvent POST body=\(bodyStr.prefix(4000))")
        }
        let data = try await request(path: "\(calPath)/events", method: "POST", body: body)
        if let respStr = String(data: data, encoding: .utf8) {
            print("[ExchangeCalendar] createEvent response=\(respStr.prefix(4000))")
        }
        let created = try JSONDecoder().decode(MSEvent.self, from: data)
        return toGCalEvent(created)
    }

    func updateEvent(
        calendarId: String = "primary",
        eventId: String,
        event: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        // Always fetch the existing event and merge the patch onto it, so we
        // PATCH a FULL payload to Graph. Graph's partial-PATCH semantics are
        // documented as "fields not specified remain unchanged" — but we've
        // seen at least one quirk in the wild: PATCHing only `recurrence` on
        // a master causes Graph to silently rewrite `start`/`end` to UTC
        // midnight at `range.startDate`. The defensive full-payload approach
        // matches CalDAV's natural full-resource PUT semantics and Google's
        // own "prefer GET + UPDATE over PATCH" recommendation.
        let existing = try await getEvent(calendarId: calendarId, eventId: eventId)
        let merged = GoogleCalendarProvider.mergeExistingEventWithPatch(existing: existing, patch: event)
        let encodedEventId = eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId
        let body = try JSONSerialization.data(withJSONObject: toGraphEventJSON(merged))
        // Dump the body so we can diagnose date/tz drift in smoke tests.
        // Graph responses are silent on success; without this we can't tell
        // if a wrong-time symptom came from a wrong-time request.
        if let bodyStr = String(data: body, encoding: .utf8) {
            print("[ExchangeCalendar] updateEvent PATCH body=\(bodyStr.prefix(4000))")
        }
        let data = try await request(path: "/events/\(encodedEventId)", method: "PATCH", body: body)
        if let respStr = String(data: data, encoding: .utf8) {
            print("[ExchangeCalendar] updateEvent response=\(respStr.prefix(4000))")
        }
        let updated = try JSONDecoder().decode(MSEvent.self, from: data)
        return toGCalEvent(updated)
    }

    func deleteEvent(
        calendarId: String = "primary",
        eventId: String,
        sendUpdates: String = "all"
    ) async throws {
        let encodedEventId = eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId
        print("[ExchangeCalendar] deleteEvent id=\(eventId)")
        _ = try await request(path: "/events/\(encodedEventId)", method: "DELETE")
        print("[ExchangeCalendar] deleteEvent success")
    }

    /// Single-occurrence override (this_only): Graph exposes occurrences as
    /// distinct event resources via `/events/{master}/instances?startDateTime&endDateTime`.
    /// We find the instance whose start matches `recurrenceId`, then PATCH it
    /// directly — Graph materializes the override.
    func updateOccurrence(
        calendarId: String = "primary",
        eventId: String,
        recurrenceId: String,
        event: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        // The agent often passes an INSTANCE id (Graph instance events carry
        // their parent's id in `seriesMasterId`). Graph's
        // `/events/{id}/instances` endpoint requires the master id — resolve
        // via seriesMasterId before the instance lookup.
        let (eventId, _) = try await resolveToMaster(eventId: eventId)
        let instanceId = try await resolveInstanceId(masterId: eventId, recurrenceId: recurrenceId)
        let encodedInstanceId = instanceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? instanceId
        // Same defensive full-payload approach as `updateEvent` — fetch the
        // instance, merge the patch onto it, send everything. Without this an
        // instance PATCH that touches only `attendees` (or some other field)
        // could silently re-anchor the instance's start to the master's
        // pattern. Strip `recurrence` defensively in case it was inherited —
        // an instance/exception cannot carry a series rule and Graph 400s on
        // PATCHes that include one.
        let existingInstance = try await getEvent(eventId: instanceId)
        var instancePatch = GoogleCalendarProvider.mergeExistingEventWithPatch(existing: existingInstance, patch: event)
        instancePatch.recurrence = nil
        let body = try JSONSerialization.data(withJSONObject: toGraphEventJSON(instancePatch))
        if let bodyStr = String(data: body, encoding: .utf8) {
            print("[ExchangeCalendar] updateOccurrence PATCH body=\(bodyStr.prefix(4000))")
        }
        let data = try await request(path: "/events/\(encodedInstanceId)", method: "PATCH", body: body)
        if let respStr = String(data: data, encoding: .utf8) {
            print("[ExchangeCalendar] updateOccurrence response=\(respStr.prefix(4000))")
        }
        let updated = try JSONDecoder().decode(MSEvent.self, from: data)
        return toGCalEvent(updated)
    }

    /// Series split (this_and_following). For Graph:
    /// 1. PATCH the master's recurrence.range to {type: "endDate", endDate: splitDate - 1 day}
    ///    — Graph's `endDate` is inclusive and date-only, so we set the day before splitDate.
    /// 2. POST a new event inheriting master's fields, applying `patch`, with start/end
    ///    shifted to recurrenceId and the same pattern but no cap.
    /// On step-2 failure, attempt a best-effort revert of step 1.
    func splitSeries(
        calendarId: String = "primary",
        eventId: String,
        recurrenceId: String,
        patch: GCalEventInput,
        sendUpdates: String = "all"
    ) async throws -> GCalEvent {
        // The agent may have passed an INSTANCE id — Graph instance events
        // don't carry the series `recurrence`; only the master does. Resolve
        // via `seriesMasterId` (mapped onto `recurringEventId` by toGCalEvent)
        // so a split aimed at an occurrence id still finds the series to cap.
        let (eventId, master) = try await resolveToMaster(eventId: eventId)
        guard let masterRecurrence = master.recurrence, !masterRecurrence.isEmpty,
              let originalRRule = masterRecurrence.first(where: { $0.uppercased().hasPrefix("RRULE:") })
        else {
            throw CalendarProviderError.notSupported("Event \(eventId) is not recurring; can't split.")
        }

        // 1. Cap the master via PATCH.
        //    IMPORTANT: Graph's recurrenceRange uses a DATE-inclusive `endDate`
        //    ("occurrences ... between startDate and endDate inclusive"). We
        //    therefore can NOT round-trip through an RRULE `UNTIL` instant —
        //    its precision is lost when collapsed to a whole date, and the
        //    naive date-part of (split − 1s) is still the split day, which
        //    Graph would keep on the master. So compute the cap directly:
        //    endDate = local date of (split occurrence − 1 day). Graph also
        //    REQUIRES `startDate` on the range — supply the master's start.
        guard let capEndDate = Self.graphEndDateBefore(naiveISO: recurrenceId, allDay: master.isAllDay) else {
            throw CalendarProviderError.notSupported("Invalid recurrence_id '\(recurrenceId)' — expected naive ISO8601 (e.g. '2026-05-20T17:00:00').")
        }
        guard let masterStartDate = master.startDate else {
            throw CalendarProviderError.notSupported("Master event \(eventId) has no start date — can't build a Graph recurrence range.")
        }
        // Build the pattern from the master's RRULE (range is replaced below).
        // Pass the master's start so `FREQ=WEEKLY`/`MONTHLY`/`YEARLY` rules that
        // omit BYDAY/BYMONTHDAY get the implied field filled from DTSTART.
        var cappedRecurrence = parseRRULEToGraphRecurrence(
            GoogleCalendarProvider.stripUntilAndCount(originalRRule),
            eventStart: masterStartDate
        )
        let startDateFmt = DateFormatter()
        startDateFmt.dateFormat = "yyyy-MM-dd"
        startDateFmt.timeZone = .current
        cappedRecurrence["range"] = [
            "type": "endDate",
            "startDate": startDateFmt.string(from: masterStartDate),
            "endDate": capEndDate,
        ]
        // CRITICAL: include the master's existing start/end on the cap PATCH.
        // If we send ONLY `recurrence`, Graph silently rewrites the master's
        // `start.dateTime`/`start.timeZone` to UTC midnight at the
        // recurrence range's `startDate` — shifting the master's first
        // occurrence by the device's UTC offset (17:00 Vancouver → 00:00 UTC,
        // i.e. the previous day in PDT). Re-sending the existing wall time
        // pins the master in place. `graphNaiveDateTime` strips the offset so
        // the `dateTime` is naive in `timeZone`, per Graph's spec.
        var cappedJSON: [String: Any] = ["recurrence": cappedRecurrence]
        if let startISO = master.start?.dateTime, let startTz = master.start?.timeZone {
            cappedJSON["start"] = [
                "dateTime": Self.graphNaiveDateTime(startISO),
                "timeZone": startTz,
            ]
        }
        if let endISO = master.end?.dateTime, let endTz = master.end?.timeZone {
            cappedJSON["end"] = [
                "dateTime": Self.graphNaiveDateTime(endISO),
                "timeZone": endTz,
            ]
        }
        let cappedBody = try JSONSerialization.data(withJSONObject: cappedJSON)
        if let bodyStr = String(data: cappedBody, encoding: .utf8) {
            print("[ExchangeCalendar] splitSeries cap PATCH body=\(bodyStr.prefix(4000))")
        }
        let encodedMasterId = eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId
        let capRespData = try await request(path: "/events/\(encodedMasterId)", method: "PATCH", body: cappedBody)
        // Log the response so we can see what Graph stored — particularly the
        // master's start/end/recurrence after capping, to diagnose visible
        // "occurrence moved to earlier day" symptoms after a split.
        if let capRespStr = String(data: capRespData, encoding: .utf8) {
            print("[ExchangeCalendar] splitSeries cap PATCH response=\(capRespStr.prefix(4000))")
        }

        // 2. Build the new series — inherit master + patch overrides + start at splitDate.
        let rruleWithoutCap = GoogleCalendarProvider.stripUntilAndCount(originalRRule)
        let newSeriesInput = GoogleCalendarProvider.mergeMasterAndPatch(
            master: master,
            patch: patch,
            newStartNaiveISO: recurrenceId,
            newRecurrence: [rruleWithoutCap]
        )
        // Stamp a DETERMINISTIC `transactionId` (derived from master id +
        // recurrence_id) on the create. Graph uses transactionId to dedupe
        // POSTs — so a retry after a lost ACK on the create below won't
        // produce a duplicate series. The two-step cap-then-create is
        // otherwise not idempotent (the PATCH is, the POST isn't).
        let transactionId = GoogleCalendarProvider.deterministicSplitEventId(
            masterId: eventId, recurrenceId: recurrenceId
        )
        var createJSON = toGraphEventJSON(newSeriesInput)
        createJSON["transactionId"] = transactionId
        let calPath: String
        if calendarId == "primary" {
            calPath = ""
        } else {
            let encodedCalId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
            calPath = "/calendars/\(encodedCalId)"
        }
        do {
            let createBody = try JSONSerialization.data(withJSONObject: createJSON)
            if let bodyStr = String(data: createBody, encoding: .utf8) {
                print("[ExchangeCalendar] splitSeries new-series POST body=\(bodyStr.prefix(4000))")
            }
            let data = try await request(path: "\(calPath)/events", method: "POST", body: createBody)
            if let respStr = String(data: data, encoding: .utf8) {
                print("[ExchangeCalendar] splitSeries new-series response=\(respStr.prefix(4000))")
            }
            let created = try JSONDecoder().decode(MSEvent.self, from: data)
            return toGCalEvent(created)
        } catch ExchangeCalendarError.httpError(409, _) {
            // 409 Conflict — Graph rejected the POST as a duplicate
            // transactionId, i.e. the new series was already created on a
            // prior (lost-ACK) attempt. The split already completed; do NOT
            // revert the master cap. The queue only logs the returned id, so
            // surface a minimal success marker.
            print("[ExchangeCalendar] splitSeries: new series already exists (duplicate transactionId) — treating as success")
            return GCalEvent(
                id: "", summary: newSeriesInput.summary, location: newSeriesInput.location,
                description: newSeriesInput.description, start: nil, end: nil, attendees: nil,
                organizer: nil, recurrence: [rruleWithoutCap], transparency: newSeriesInput.transparency,
                status: "confirmed", htmlLink: nil, created: nil, updated: nil
            )
        } catch {
            // Best-effort revert: restore the master's original recurrence.
            // SAME Graph quirk as the cap PATCH above — sending ONLY
            // `recurrence` causes Graph to silently rewrite the master's
            // start/end to UTC midnight at `range.startDate`. Include the
            // master's existing start/end so its first occurrence stays put.
            var revertInput = GCalEventInput()
            revertInput.recurrence = masterRecurrence
            if let startISO = master.start?.dateTime,
               let startTz = master.start?.timeZone {
                revertInput.startDateTime = startISO
                revertInput.startTimeZone = startTz
            }
            if let endISO = master.end?.dateTime,
               let endTz = master.end?.timeZone {
                revertInput.endDateTime = endISO
                revertInput.endTimeZone = endTz
            }
            let revertBody = try? JSONSerialization.data(withJSONObject: toGraphEventJSON(revertInput))
            if let revertBody {
                if let bodyStr = String(data: revertBody, encoding: .utf8) {
                    print("[ExchangeCalendar] splitSeries revert PATCH body=\(bodyStr.prefix(4000))")
                }
                _ = try? await request(path: "/events/\(encodedMasterId)", method: "PATCH", body: revertBody)
            }
            throw error
        }
    }

    /// Graph `recurrenceRange.endDate` for capping a series so the occurrence
    /// at `naiveISO` and everything after is excluded. Graph's endDate is
    /// DATE-inclusive, so this is the local date of (split occurrence − 1 day).
    /// `allDay` doesn't change the math here (the result is a date either way)
    /// but is accepted for signature symmetry with the Google helper.
    /// Returns nil if `naiveISO` can't be parsed.
    static func graphEndDateBefore(naiveISO: String, allDay: Bool) -> String? {
        let dtFmt = DateFormatter()
        dtFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        dtFmt.timeZone = .current
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone = .current
        let parsed = dtFmt.date(from: naiveISO)
            ?? dateFmt.date(from: String(naiveISO.prefix(10)))
        guard let date = parsed else { return nil }
        // Calendar arithmetic, not a flat 86400s — a DST-transition day is 23h
        // or 25h of local time, so `addingTimeInterval(-86400)` can land on the
        // wrong calendar day and cap the series a day early/late.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        guard let dayBefore = cal.date(byAdding: .day, value: -1, to: date) else { return nil }
        let out = DateFormatter()
        out.dateFormat = "yyyy-MM-dd"
        out.timeZone = .current
        return out.string(from: dayBefore)
    }

    /// If `eventId` points to an OCCURRENCE of a recurring series, fetch the
    /// master and return its id + event. Otherwise return the fetched event
    /// as the master. Graph's instance events carry the parent series id in
    /// `seriesMasterId`, which `toGCalEvent` maps onto `GCalEvent.recurringEventId`.
    /// Same rationale as GoogleCalendarProvider.resolveToMaster — the agent
    /// commonly passes an instance id from calendar_read output, and the
    /// series-level operations (splitSeries / updateOccurrence instances
    /// endpoint) require the master id.
    private func resolveToMaster(eventId: String) async throws -> (id: String, event: GCalEvent) {
        let fetched = try await getEvent(eventId: eventId)
        if let masterId = fetched.recurringEventId, !masterId.isEmpty, masterId != eventId {
            let master = try await getEvent(eventId: masterId)
            return (masterId, master)
        }
        return (eventId, fetched)
    }

    /// Find the Graph instance id for the occurrence starting at `recurrenceId`
    /// by querying a wide-enough window around that time to tolerate DST and
    /// device/event timezone deltas. See `GoogleCalendarProvider.resolveInstanceId`
    /// for the ±25h rationale; we use the same window for parity so a DST-
    /// adjacent occurrence resolves the same way on both backends.
    private func resolveInstanceId(masterId: String, recurrenceId: String) async throws -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = .current
        guard let centerDate = fmt.date(from: recurrenceId) else {
            // Fall back to the date-only form (e.g. "2026-05-20" for an all-day
            // recurring event) before declaring the recurrenceId malformed —
            // parity with GoogleCalendarProvider.resolveInstanceId. Recurse with
            // a normalized full-day form so the rest of the path is one branch.
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd"
            dateFmt.timeZone = TimeZone(identifier: "UTC")
            guard dateFmt.date(from: String(recurrenceId.prefix(10))) != nil else {
                throw ExchangeCalendarError.eventNotFound
            }
            return try await resolveInstanceId(
                masterId: masterId,
                recurrenceId: "\(recurrenceId.prefix(10))T00:00:00"
            )
        }
        let windowSeconds: TimeInterval = 25 * 60 * 60
        let minDate = centerDate.addingTimeInterval(-windowSeconds)
        let maxDate = centerDate.addingTimeInterval(windowSeconds)
        let utcFmt = DateFormatter()
        utcFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        utcFmt.timeZone = TimeZone(identifier: "UTC")
        let startQS = utcFmt.string(from: minDate)
        let endQS = utcFmt.string(from: maxDate)

        let encodedMaster = masterId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? masterId
        let encodedStart = startQS.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? startQS
        let encodedEnd = endQS.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? endQS
        let data = try await request(path: "/events/\(encodedMaster)/instances?startDateTime=\(encodedStart)&endDateTime=\(encodedEnd)&$select=id,start")

        struct InstancesResponse: Decodable { let value: [MSEvent] }
        let resp = try JSONDecoder().decode(InstancesResponse.self, from: data)
        // Match by day prefix first — handles DST shifts inside the window. If
        // multiple instances came back and none day-matches, refuse to guess
        // (consistent with Google's behavior).
        let dayPrefix = String(recurrenceId.prefix(10))
        if let dayMatch = resp.value.first(where: { ($0.start?.dateTime ?? "").hasPrefix(dayPrefix) }),
           let id = dayMatch.id {
            return id
        }
        if resp.value.count == 1, let id = resp.value[0].id {
            return id
        }
        throw ExchangeCalendarError.eventNotFound
    }

    // MARK: - HTTP

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let token = try await accessToken(false)
        // `Prefer: outlook.timezone` controls the timezone Graph uses in the
        // response's `start.timeZone` / `end.timeZone`. Without it Graph
        // defaults to UTC. We used to set it to `"UTC"` explicitly, which
        // caused a nasty round-trip bug: a freshly-created event stored in
        // the user's local zone was returned as `{dateTime: "...UTC time...",
        // timeZone: "UTC"}`; `mergeMasterAndPatch` then inherited that "UTC"
        // for the split's new series, and the POST stored the new series with
        // `timeZone: "UTC"` — shifting the displayed wall time of every
        // post-split occurrence by the user's UTC offset (e.g. 16:00 PDT →
        // 16:00 UTC = 09:00 PDT visible). Use the device's IANA zone so the
        // round-trip preserves the user's intended wall time.
        let prefTz = TimeZone.current.identifier
        let headers = ["Prefer": "outlook.timezone=\"\(prefTz)\""]
        let result = try await performHTTPRequest(url: baseURL + path, method: method, body: body, token: token, extraHeaders: headers, logLabel: "ExchangeCalendar")

        if let data = result.data {
            return data
        }

        // 401 — token expired, force refresh and retry once
        if result.statusCode == 401 {
            print("[ExchangeCalendar] Token expired, refreshing...")
            let freshToken = try await accessToken(true)
            let retry = try await performHTTPRequest(url: baseURL + path, method: method, body: body, token: freshToken, extraHeaders: headers, logLabel: "ExchangeCalendar")
            // `headers` already carries the local-tz Prefer from the first attempt above.
            if let data = retry.data {
                return data
            }
            throw ExchangeCalendarError.httpError(retry.statusCode, nil)
        }

        // 403 — missing scope
        if result.statusCode == 403 {
            throw ExchangeCalendarError.missingScope
        }

        throw ExchangeCalendarError.httpError(result.statusCode, result.data)
    }

    // MARK: - Model Mapping (Graph → GCal)

    /// True when Graph returned an event with no subject, no attendees, no location,
    /// and no body. Such rows come from room-mailbox calendar processing
    /// (`DeleteSubject=$True`) or from private events on shared calendars — the user
    /// can't reference them, and surfacing them to the agent crowds out real events.
    /// Applied only on list paths (`listEvents`); single-event lookups
    /// (`getEvent`/`createEvent`/`updateEvent`) keep returning the underlying event.
    /// Internal (not private) so unit tests can call it.
    func isEmptySurfaceEvent(_ e: MSEvent) -> Bool {
        let hasSubject = !(e.subject?.isEmpty ?? true)
        let hasAttendees = !(e.attendees?.isEmpty ?? true)
        let hasLocation = !(e.location?.displayName?.isEmpty ?? true)
        let hasBody = !(e.bodyPreview?.isEmpty ?? true)
        return !hasSubject && !hasAttendees && !hasLocation && !hasBody
    }

    func toGCalEvent(_ e: MSEvent) -> GCalEvent {
        let transparency: String?
        switch e.showAs {
        case "free": transparency = "transparent"
        case "busy", "tentative", "oof", "workingElsewhere": transparency = "opaque"
        default: transparency = nil
        }

        let attendees: [GCalAttendee]? = e.attendees?.map { att in
            GCalAttendee(
                email: att.emailAddress?.address,
                displayName: att.emailAddress?.name,
                responseStatus: mapResponseStatus(att.status?.response),
                organizer: false,
                self: false
            )
        }

        let organizer: GCalOrganizer? = e.organizer.map { org in
            GCalOrganizer(
                email: org.emailAddress?.address,
                displayName: org.emailAddress?.name,
                self: false
            )
        }

        // Map recurrence from Graph PatternedRecurrence → RFC 5545 RRULE.
        // CRITICAL: Graph's `pattern.type` is NOT an RFC 5545 FREQ value —
        // `absoluteMonthly`/`relativeMonthly`/`absoluteYearly`/`relativeYearly`
        // must be classified into `FREQ=MONTHLY`/`FREQ=YEARLY` with the
        // distinguishing BY* parts. Blindly uppercasing the Graph type emits
        // `FREQ=ABSOLUTEMONTHLY` — an invalid RRULE that (a) shows garbage to
        // the LLM and (b) round-trips through `parseRRULEToGraphRecurrence` to
        // `default → daily`, silently turning a monthly Exchange series daily
        // on split.
        let recurrence: [String]? = e.recurrence.map { rec in
            guard let pattern = rec.pattern else { return [] }
            let dayMap = ["sunday": "SU", "monday": "MO", "tuesday": "TU", "wednesday": "WE", "thursday": "TH", "friday": "FR", "saturday": "SA"]
            let byDay = (pattern.daysOfWeek ?? []).compactMap { dayMap[$0.lowercased()] }.joined(separator: ",")
            let indexToSetPos = ["first": 1, "second": 2, "third": 3, "fourth": 4, "last": -1]
            let bySetPos = pattern.index.flatMap { indexToSetPos[$0.lowercased()] }

            var parts: [String] = []
            switch pattern.type?.lowercased() {
            case "daily":
                parts.append("FREQ=DAILY")
            case "weekly":
                parts.append("FREQ=WEEKLY")
                if !byDay.isEmpty { parts.append("BYDAY=\(byDay)") }
            case "absolutemonthly":
                parts.append("FREQ=MONTHLY")
                if let d = pattern.dayOfMonth { parts.append("BYMONTHDAY=\(d)") }
            case "relativemonthly":
                parts.append("FREQ=MONTHLY")
                if !byDay.isEmpty { parts.append("BYDAY=\(byDay)") }
                if let sp = bySetPos { parts.append("BYSETPOS=\(sp)") }
            case "absoluteyearly":
                parts.append("FREQ=YEARLY")
                if let m = pattern.month { parts.append("BYMONTH=\(m)") }
                if let d = pattern.dayOfMonth { parts.append("BYMONTHDAY=\(d)") }
            case "relativeyearly":
                parts.append("FREQ=YEARLY")
                if let m = pattern.month { parts.append("BYMONTH=\(m)") }
                if !byDay.isEmpty { parts.append("BYDAY=\(byDay)") }
                if let sp = bySetPos { parts.append("BYSETPOS=\(sp)") }
            default:
                // Unknown Graph type — emit a bare weekly so the value is at
                // least a valid FREQ rather than garbage.
                parts.append("FREQ=WEEKLY")
                if !byDay.isEmpty { parts.append("BYDAY=\(byDay)") }
            }
            if let interval = pattern.interval, interval > 1 { parts.append("INTERVAL=\(interval)") }
            // Gate UNTIL/COUNT emission on `range.type` — Graph ALWAYS fills
            // `endDate` (with the sentinel "0001-01-01" for `noEnd`) and
            // ALWAYS fills `numberOfOccurrences` (with 0 for non-numbered).
            // Without the type check we emit `UNTIL=00010101` for every
            // open-ended series, which (a) shows the LLM/user a garbage RRULE
            // and (b) round-trips on subsequent edits into Graph as a real
            // capped series ending in year 0001.
            let rangeType = rec.range?.type?.lowercased()
            if rangeType == "enddate",
               let endDate = rec.range?.endDate, !endDate.isEmpty, endDate != "0001-01-01" {
                parts.append("UNTIL=\(endDate.replacingOccurrences(of: "-", with: ""))")
            } else if rangeType == "numbered",
                      let count = rec.range?.numberOfOccurrences, count > 0 {
                parts.append("COUNT=\(count)")
            }
            // `noEnd` (or any unknown type) → emit no UNTIL/COUNT.
            return ["RRULE:" + parts.joined(separator: ";")]
        }

        return GCalEvent(
            id: e.id,
            summary: e.subject,
            location: e.location?.displayName,
            description: e.bodyPreview,
            start: toGCalDateTime(e.start, isAllDay: e.isAllDay ?? false),
            end: toGCalDateTime(e.end, isAllDay: e.isAllDay ?? false),
            attendees: attendees,
            organizer: organizer,
            recurrence: recurrence,
            transparency: transparency,
            status: e.isCancelled == true ? "cancelled" : "confirmed",
            htmlLink: e.webLink,
            created: e.createdDateTime,
            updated: e.lastModifiedDateTime,
            // Graph's seriesMasterId → our recurringEventId, so calendar_search
            // enrichment can fetch the master's rule for Exchange instances too.
            recurringEventId: e.seriesMasterId
        )
    }

    private func toGCalDateTime(_ dt: MSDateTimeZone?, isAllDay: Bool) -> GCalDateTime? {
        guard let dt else { return nil }
        if isAllDay {
            // All-day: extract date-only from dateTime (format: "2024-01-15T00:00:00.0000000")
            let dateOnly = String((dt.dateTime ?? "").prefix(10))
            return GCalDateTime(dateTime: nil, date: dateOnly, timeZone: nil)
        }
        // Timed event: convert to RFC 3339
        let rfc3339 = convertToRFC3339(dt.dateTime ?? "", timeZone: dt.timeZone ?? "UTC")
        return GCalDateTime(dateTime: rfc3339, date: nil, timeZone: dt.timeZone)
    }

    private func convertToRFC3339(_ dateTime: String, timeZone: String) -> String {
        // Graph returns "2024-01-15T14:30:00.0000000" with separate timeZone
        // We need to convert to RFC 3339: "2024-01-15T14:30:00+00:00"
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: timeZone) ?? .current

        // Try parsing with fractional seconds
        let cleanDateTime = String(dateTime.prefix(19)) // Strip fractional seconds
        guard let date = fmt.date(from: cleanDateTime) else { return dateTime }

        return date.iso8601String(timeZone: TimeZone(identifier: timeZone) ?? .current)
    }

    /// Drop the trailing offset/`Z` from an ISO 8601 datetime so the resulting
    /// string is the naive wall-time form Graph expects in `start.dateTime` /
    /// `end.dateTime`. Searches AFTER the `T` so the date's `-` separators
    /// aren't mistaken for an offset.
    nonisolated static func graphNaiveDateTime(_ iso: String) -> String {
        guard let tIdx = iso.firstIndex(of: "T") else { return iso }
        let afterT = iso.index(after: tIdx)
        let timePart = iso[afterT...]
        if let offsetIdx = timePart.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            return String(iso[..<offsetIdx])
        }
        return iso
    }

    nonisolated func toGraphEventJSON(_ input: GCalEventInput) -> [String: Any] {
        var json: [String: Any] = [:]

        if let summary = input.summary { json["subject"] = summary }
        if let location = input.location { json["location"] = ["displayName": location] }
        if let desc = input.description { json["body"] = ["contentType": "text", "content": desc] }

        // showAs (transparency mapping)
        if let transparency = input.transparency {
            json["showAs"] = transparency == "transparent" ? "free" : "busy"
        }

        // Start. Graph's `dateTime` is a "combined date and time representation
        // in ISO 8601 format" WITHOUT a timezone designator — the separate
        // `timeZone` field supplies that. Sending the RFC 3339 offset-bearing
        // form (e.g. "2026-05-15T20:00:00-0700") alongside `timeZone:"…"`
        // double-specifies the instant; Outlook web then renders the event in
        // the user's account timezone with the wall-time shifted by the
        // double-conversion, which manifests as a calendar entry appearing on
        // the wrong DAY. Strip the offset so the value is unambiguously
        // "20:00:00 in <timeZone>".
        if let startDateTime = input.startDateTime {
            json["start"] = [
                "dateTime": Self.graphNaiveDateTime(startDateTime),
                "timeZone": input.startTimeZone ?? TimeZone.current.identifier,
            ]
            json["isAllDay"] = false
        } else if let startDate = input.startDate {
            json["start"] = [
                "dateTime": "\(startDate)T00:00:00",
                "timeZone": "UTC",
            ]
            json["isAllDay"] = true
        }

        // End
        if let endDateTime = input.endDateTime {
            json["end"] = [
                "dateTime": Self.graphNaiveDateTime(endDateTime),
                "timeZone": input.endTimeZone ?? TimeZone.current.identifier,
            ]
        } else if let endDate = input.endDate {
            json["end"] = [
                "dateTime": "\(endDate)T00:00:00",
                "timeZone": "UTC",
            ]
        }

        // Attendees
        if let attendees = input.attendees {
            json["attendees"] = attendees.map { a -> [String: Any] in
                var obj: [String: Any] = ["emailAddress": ["address": a.email]]
                if let name = a.name {
                    obj["emailAddress"] = ["address": a.email, "name": name]
                }
                obj["type"] = "required"
                return obj
            }
        }

        // Recurrence. Graph REQUIRES `recurrenceRange.startDate` for every
        // range type (per the recurrenceRange spec). `parseRRULEToGraphRecurrence`
        // can't know the start (an RRULE has no DTSTART), so we inject it here
        // from the event's own start — which is exactly what Graph wants
        // ("Must be the same value as the start property of the recurring event").
        if let recurrence = input.recurrence, let rrule = recurrence.first {
            // Derive the event's start so weekly/monthly/yearly rules that omit
            // BYDAY/BYMONTHDAY get the implied field filled from it (Graph
            // rejects a weekly pattern with no daysOfWeek, etc.).
            let recEventStart: Date? = {
                if let sdt = input.startDateTime { return Date.fromISO8601(sdt) }
                if let sd = input.startDate {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    f.timeZone = .current
                    return f.date(from: sd)
                }
                return nil
            }()
            var graphRec = parseRRULEToGraphRecurrence(rrule, eventStart: recEventStart)
            if var range = graphRec["range"] as? [String: Any], range["startDate"] == nil {
                let startDateStr: String? = {
                    if let sd = input.startDate { return sd }                       // already YYYY-MM-DD
                    if let sdt = input.startDateTime { return String(sdt.prefix(10)) } // RFC3339 → date part
                    return nil
                }()
                if let startDateStr {
                    range["startDate"] = startDateStr
                    graphRec["range"] = range
                }
            }
            json["recurrence"] = graphRec
        }

        return json
    }

    /// Convert an RFC 5545 `RRULE` to a Microsoft Graph `patternedRecurrence`.
    ///
    /// Graph's `recurrencePattern.type` is a CLOSED enum — `daily`, `weekly`,
    /// `absoluteMonthly`, `relativeMonthly`, `absoluteYearly`, `relativeYearly`
    /// — and "any property that does not have a supported value results in an
    /// error". So `FREQ=MONTHLY`/`FREQ=YEARLY` can NOT be passed through as
    /// `type: "monthly"`/`"yearly"`; they must be classified into the
    /// absolute/relative variants. Each variant also has REQUIRED companion
    /// fields (`weekly` → `daysOfWeek`, `absoluteMonthly` → `dayOfMonth`, …).
    ///
    /// When the RRULE omits the field Graph needs, RFC 5545 says it's implied
    /// by `DTSTART` (e.g. `FREQ=WEEKLY` with no `BYDAY` recurs on DTSTART's
    /// weekday). `eventStart` is that DTSTART — it lets us fill the implied
    /// field correctly instead of emitting a body Graph rejects with HTTP 400.
    nonisolated func parseRRULEToGraphRecurrence(_ rrule: String, eventStart: Date?) -> [String: Any] {
        let parts = rrule.replacingOccurrences(of: "RRULE:", with: "").split(separator: ";")
        var freq = "weekly"
        var interval = 1
        var count: Int?
        var until: String?
        var byDay: [String] = []   // raw tokens, may carry an ordinal prefix ("2FR", "-1MO")
        var byMonthDay: Int?
        var byMonth: Int?
        var bySetPos: Int?

        let abbrevToDay = ["SU": "sunday", "MO": "monday", "TU": "tuesday", "WE": "wednesday", "TH": "thursday", "FR": "friday", "SA": "saturday"]

        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch String(kv[0]).uppercased() {
            case "FREQ": freq = String(kv[1]).lowercased()
            case "INTERVAL": interval = Int(kv[1]) ?? 1
            case "COUNT": count = Int(kv[1])
            case "UNTIL": until = String(kv[1])
            case "BYDAY": byDay = String(kv[1]).split(separator: ",").map { String($0).uppercased() }
            case "BYMONTHDAY": byMonthDay = Int(kv[1])
            case "BYMONTH": byMonth = Int(kv[1])
            case "BYSETPOS": bySetPos = Int(kv[1])
            default: break
            }
        }

        var range: [String: Any] = ["type": "noEnd"]
        if let count {
            range = ["type": "numbered", "numberOfOccurrences": count]
        } else if let until {
            // RFC 5545 UNTIL can be `YYYYMMDD` (all-day), `YYYYMMDDTHHMMSS`
            // (local), or `YYYYMMDDTHHMMSSZ` (UTC) — Graph's endDate is a bare
            // date, so take the leading 8 date digits regardless of form.
            // NOTE: callers that need a precise split should NOT route through
            // here (Graph's date-inclusive endDate loses the instant). See
            // `splitSeries` / `graphEndDateBefore`. This path exists for plain
            // create/update of an already-date-bounded series.
            let digits = until.filter { $0.isNumber }
            if digits.count >= 8 {
                let d = String(digits.prefix(8))
                let endDate = "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2))"
                range = ["type": "endDate", "endDate": endDate]
            }
            // If we can't recover 8 date digits, leave range as noEnd rather
            // than emitting a malformed endDate that Graph would reject.
        }

        // Calendar fields implied by DTSTART when the RRULE doesn't spell them out.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let startComps = eventStart.map { cal.dateComponents([.weekday, .day, .month], from: $0) }
        let startWeekday = startComps?.weekday.map { weekdayNames[($0 - 1) % 7] }
        let startDayOfMonth = startComps?.day
        let startMonth = startComps?.month

        // BYDAY tokens → plain day names; the ordinal prefix ("2FR") feeds `index`.
        let plainDays = byDay.compactMap { abbrevToDay[String($0.suffix(2))] }
        let byDayOrdinal: Int? = {
            guard let first = byDay.first else { return nil }
            let prefix = first.dropLast(2)
            return prefix.isEmpty ? nil : Int(prefix)
        }()
        func weekIndex(_ n: Int) -> String {
            switch n {
            case 1: return "first"
            case 2: return "second"
            case 3: return "third"
            case 4: return "fourth"
            default: return "last"   // 5+ or negative ("-1FR" = last Friday)
            }
        }

        var pattern: [String: Any] = ["interval": interval]
        switch freq {
        case "daily":
            pattern["type"] = "daily"

        case "weekly":
            pattern["type"] = "weekly"
            // Graph REQUIRES daysOfWeek + firstDayOfWeek for weekly. RFC 5545:
            // FREQ=WEEKLY with no BYDAY recurs on DTSTART's weekday.
            pattern["daysOfWeek"] = !plainDays.isEmpty ? plainDays
                : (startWeekday.map { [$0] } ?? ["monday"])
            pattern["firstDayOfWeek"] = "sunday"

        case "monthly":
            if !plainDays.isEmpty {
                // BYDAY present → "the 2nd Friday" style → relativeMonthly.
                pattern["type"] = "relativeMonthly"
                pattern["daysOfWeek"] = plainDays
                pattern["index"] = weekIndex(byDayOrdinal ?? bySetPos ?? 1)
            } else {
                // absoluteMonthly REQUIRES dayOfMonth — from BYMONTHDAY or DTSTART.
                pattern["type"] = "absoluteMonthly"
                pattern["dayOfMonth"] = byMonthDay ?? startDayOfMonth ?? 1
            }

        case "yearly":
            if !plainDays.isEmpty {
                pattern["type"] = "relativeYearly"
                pattern["daysOfWeek"] = plainDays
                pattern["month"] = byMonth ?? startMonth ?? 1
                pattern["index"] = weekIndex(byDayOrdinal ?? bySetPos ?? 1)
            } else {
                // absoluteYearly REQUIRES dayOfMonth + month.
                pattern["type"] = "absoluteYearly"
                pattern["dayOfMonth"] = byMonthDay ?? startDayOfMonth ?? 1
                pattern["month"] = byMonth ?? startMonth ?? 1
            }

        default:
            // Unknown FREQ (SECONDLY/MINUTELY/HOURLY — not expressible in Graph).
            // Emit a well-formed daily body rather than an invalid `type`.
            pattern["type"] = "daily"
        }

        return [
            "pattern": pattern,
            "range": range,
        ]
    }

    private func mapResponseStatus(_ status: String?) -> String? {
        switch status {
        case "accepted": return "accepted"
        case "declined": return "declined"
        case "tentativelyAccepted": return "tentative"
        case "notResponded", "none": return "needsAction"
        default: return status
        }
    }

    private func msColorToHex(_ color: String?) -> String? {
        // Graph uses named colors; return a reasonable hex
        switch color {
        case "auto", nil: return nil
        case "lightBlue": return "#4285F4"
        case "lightGreen": return "#0B8043"
        case "lightOrange": return "#F4511E"
        case "lightGray": return "#616161"
        case "lightYellow": return "#E4C441"
        case "lightTeal": return "#039BE5"
        case "lightPink": return "#D81B60"
        case "lightBrown": return "#795548"
        case "lightRed": return "#D50000"
        default: return nil
        }
    }

}

// MARK: - Errors

enum ExchangeCalendarError: Error {
    case missingScope
    case httpError(Int, Data?)
    case eventNotFound
}

// MARK: - Microsoft Graph Calendar Response Models

private struct MSCalendarListResponse: Decodable {
    let value: [MSCalendar]
}

private struct MSCalendar: Decodable {
    let id: String
    let name: String?
    let isDefaultCalendar: Bool?
    let color: String?
}

// Decodable shapes for Microsoft Graph calendar payloads. Internal (not private)
// so unit tests in `TabMailTests/Providers/ExchangeCalendarTests.swift` can decode
// JSON fixtures into `MSEvent` to exercise `toGCalEvent`.
struct MSEventListResponse: Decodable {
    let value: [MSEvent]
}

struct MSEvent: Decodable {
    let id: String?
    let subject: String?
    let location: MSLocation?
    let bodyPreview: String?
    let start: MSDateTimeZone?
    let end: MSDateTimeZone?
    let attendees: [MSAttendee]?
    let organizer: MSOrganizer?
    let recurrence: MSPatternedRecurrence?
    let showAs: String?
    let isCancelled: Bool?
    let isAllDay: Bool?
    let webLink: String?
    let createdDateTime: String?
    let lastModifiedDateTime: String?
    /// Set on `occurrence`/`exception` rows (calendarView expansion) — points
    /// to the series master. Graph's analogue of Google's `recurringEventId`.
    /// We map it onto `GCalEvent.recurringEventId` so the calendar_search
    /// enrichment (`resolveMasterRecurrence`) can fetch the master's rule.
    let seriesMasterId: String?
}

struct MSLocation: Decodable {
    let displayName: String?
}

struct MSDateTimeZone: Decodable {
    let dateTime: String?
    let timeZone: String?
}

struct MSAttendee: Decodable {
    let emailAddress: MSEmailAddress?
    let status: MSResponseStatus?
    let type: String?
}

struct MSEmailAddress: Decodable {
    let name: String?
    let address: String?
}

struct MSResponseStatus: Decodable {
    let response: String?
}

struct MSOrganizer: Decodable {
    let emailAddress: MSEmailAddress?
}

struct MSPatternedRecurrence: Decodable {
    let pattern: MSRecurrencePattern?
    let range: MSRecurrenceRange?
}

struct MSRecurrencePattern: Decodable {
    let type: String?
    let interval: Int?
    let daysOfWeek: [String]?
    let dayOfMonth: Int?
    let index: String?   // first | second | third | fourth | last
    let month: Int?
}

struct MSRecurrenceRange: Decodable {
    let type: String?
    let endDate: String?
    let numberOfOccurrences: Int?
}
